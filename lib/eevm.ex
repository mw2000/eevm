defmodule EEVM do
  @moduledoc """
  EEVM — Ethereum Virtual Machine implementation in Elixir.

  Execution engine for every fork from Frontier to Osaka (Osaka in
  progress): full opcode set, all precompiles (including BLS12-381 via NIF),
  transaction validation and processing, whole blocks, MPT-backed state root,
  and harnesses for the official `ethereum/tests` suites. Conformance with
  those suites is still in progress.

  ## Quick Start

      iex> {:ok, result} = EEVM.run(<<0x60, 2, 0x60, 3, 0x01, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xF3>>)
      iex> result.status
      :success
      iex> :binary.decode_unsigned(result.return_data)
      5

  ## Module Map

  The public API:

  - `EEVM` — run bytecode (`run/2`), execute a signed transaction
    (`transact/4`), and disassemble bytecode
  - `EEVM.Config` — the hardfork, chain id, and custom precompiles
  - `EEVM.BlockEnv` and `EEVM.TxEnv` — the block and transaction environment
    code executes in
  - `EEVM.CallResult` and `EEVM.TransactionResult` — what `run/2` and
    `transact/4` return
  - `EEVM.Error` — every error reason
  - `EEVM.Transaction` and its `Envelope` and `Signer` — transaction structs,
    wire encoding, and signatures
  - `EEVM.Block` — block RLP codec, validation, building, and execution
  - `EEVM.Database` and `EEVM.Database.InMemory` — account and storage state

  Extension points: `EEVM.Precompile` (custom precompiles), `EEVM.Tracer`
  (EIP-3155 traces), `EEVM.Block.Processor` (custom transaction executors),
  and `EEVM.SystemContracts` (genesis setup). Modules grouped under
  "Internals" in the docs are implementation details and may change in any
  release.
  """

  alias EEVM.Block.Bloom
  alias EEVM.{BlockEnv, CallResult, Database, Handler, TransactionResult}
  alias EEVM.Context.Contract
  alias EEVM.Database.InMemory
  alias EEVM.Handler.{PostExecution, Validation}
  alias EEVM.Interpreter
  alias EEVM.Interpreter.{MachineState, Stack}
  alias EEVM.Tracer

  @address_limit 2 ** 160

  @execute_opts [:gas, :hardfork, :config, :db, :block, :tx, :contract]

  @run_opts [
    :config,
    :hardfork,
    :db,
    :block,
    :tx,
    :tracer,
    gas: 1_000_000,
    address: 0,
    caller: 0,
    value: 0,
    calldata: <<>>,
    debug: false
  ]

  @doc """
  Runs `code` as a message call, with no transaction rules: no signature,
  nonce, intrinsic gas, or fee checks.

  Use it to test bytecode or to probe a contract `eth_call`-style. To run a
  signed transaction, use `transact/4`.

  ## Options

    - `:config` — the `EEVM.Config` to run under, or `:hardfork` for the
      shorthand `EEVM.Config.new(hardfork)` (default `:cancun`)
    - `:gas` — the gas limit (default 1,000,000)
    - `:db` — the `EEVM.Database` (default: an empty `EEVM.Database.InMemory`)
    - `:block` and `:tx` — the `EEVM.BlockEnv` and `EEVM.TxEnv` the code sees
    - `:address`, `:caller`, `:value`, `:calldata` — the executing account,
      CALLER, CALLVALUE, and the call's input (defaults `0`, `0`, `0`, `<<>>`)
    - `:tracer` — `true` or an `EEVM.Tracer` to record an EIP-3155 trace,
      returned as `result.trace`
    - `:debug` — `true` to return the final stack as `result.stack`

  Any other option raises `ArgumentError`.

  Returns `{:ok, %EEVM.CallResult{}}` however execution ends; check
  `result.status`. Writes stay in `result.db`'s overlay and are listed in
  `result.changes`; nothing is committed to the backend. A backend read
  failure returns `{:error, {:database, reason}}`.

  ## Examples

      iex> {:ok, result} = EEVM.run(<<0x60, 0x0A, 0x60, 0x14, 0x01, 0x00>>, debug: true)
      iex> {result.status, result.stack, result.gas_used}
      {:success, [30], 9}

      iex> {:ok, result} = EEVM.run(<<0xFE>>, gas: 100)
      iex> {result.status, result.gas_left}
      {{:halt, :invalid_opcode}, 0}
  """
  @spec run(binary(), keyword()) :: {:ok, CallResult.t()} | {:error, EEVM.Error.reason()}
  def run(code, opts \\ []) when is_binary(code) do
    opts = Keyword.validate!(opts, @run_opts)
    db = Keyword.get_lazy(opts, :db, &InMemory.new/0)

    contract =
      Contract.new(
        address: opts[:address],
        caller: opts[:caller],
        callvalue: opts[:value],
        calldata: opts[:calldata]
      )

    Database.catch_read_errors(fn ->
      state =
        Interpreter.run(
          code,
          [
            gas: opts[:gas],
            db: db,
            config: Validation.resolve_config(opts),
            contract: contract,
            tracer: Validation.resolve_tracer(opts)
          ] ++ Keyword.take(opts, [:block, :tx])
        )

      status = PostExecution.status(state.status)
      db_after = if status == :success, do: state.db, else: db

      {:ok,
       %CallResult{
         status: status,
         return_data: state.frame.return_data,
         gas_used: opts[:gas] - state.frame.gas,
         gas_left: state.frame.gas,
         logs: if(status == :success, do: Enum.reverse(state.substate.logs), else: []),
         db: db_after,
         changes: Database.changes(db_after),
         trace: state.tracer,
         stack: if(opts[:debug], do: Stack.to_list(state.frame.stack))
       }}
    end)
  end

  @doc """
  Validates and executes one signed transaction against `db` in the block
  environment `block`: decode, recover the sender, validate, charge gas,
  execute, refund, and pay the coinbase.

  `tx` is a transaction struct (see `EEVM.Transaction`) or its raw signed
  bytes. Options are `:config` (or the `:hardfork` shorthand) and `:tracer`,
  as for `run/2`.

  Returns `{:ok, %EEVM.TransactionResult{}}` for any transaction that passes
  validation, including reverted and halted ones, or `{:error, reason}` with
  a reason from `EEVM.Error`, leaving `db` unchanged.
  """
  @spec transact(Handler.wire_tx(), BlockEnv.t(), Database.t(), Handler.opts()) ::
          {:ok, TransactionResult.t()} | {:error, EEVM.Error.reason()}
  defdelegate transact(tx, block, db, opts \\ []), to: Handler, as: :execute

  @doc """
  Returns an address as the integer eevm uses everywhere: from a hex string
  (with or without `0x`, any case), a 20-byte binary, or an integer.

  Raises `ArgumentError` for anything else.

  ## Examples

      iex> EEVM.address("0x00000000000000000000000000000000000000Ff")
      255
      iex> EEVM.address(<<0xB0B::160>>)
      2827
  """
  @spec address(String.t() | <<_::160>> | non_neg_integer()) :: non_neg_integer()
  def address(<<value::unsigned-big-160>>), do: value
  def address(value) when is_integer(value) and value >= 0 and value < @address_limit, do: value
  def address("0x" <> hex), do: address(hex)

  def address(hex) when is_binary(hex) and byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<value::unsigned-big-160>>} -> value
      :error -> raise ArgumentError, "not a hex address: #{inspect(hex)}"
    end
  end

  def address(other), do: raise(ArgumentError, "not an address: #{inspect(other)}")

  @doc """
  Renders bytes or a non-negative integer as `0x`-prefixed lowercase hex.

  A binary keeps every byte, so pass a hash or `<<address::160>>` to keep its
  width; an integer renders as a JSON-RPC quantity, without leading zeros.

  ## Examples

      iex> EEVM.hex(<<0, 1, 0xAB>>)
      "0x0001ab"
      iex> EEVM.hex(255)
      "0xff"
      iex> EEVM.hex(0)
      "0x0"
  """
  @spec hex(binary() | non_neg_integer()) :: String.t()
  def hex(bytes) when is_binary(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)

  def hex(value) when is_integer(value) and value >= 0,
    do: "0x" <> String.downcase(Integer.to_string(value, 16))

  @doc """
  Executes EVM bytecode and returns the final machine state.

  Deprecated: use `run/2`, which returns an `EEVM.CallResult`. This takes the
  options `:gas`, `:hardfork`, `:config`, `:db`, `:block`, `:tx`, and
  `:contract`.
  """
  @deprecated "Use EEVM.run/2"
  @spec execute(binary(), keyword()) :: MachineState.t()
  def execute(bytecode, opts \\ []) do
    Interpreter.run(bytecode, Keyword.validate!(opts, @execute_opts))
  end

  @doc """
  Executes bytecode with an opcode-level tracer attached and returns
  `{final_state, tracer}`.

  Deprecated: use `run(code, tracer: true)`, which returns the trace as
  `result.trace`.
  """
  @deprecated "Use EEVM.run/2 with tracer: true"
  @spec trace(binary(), keyword()) :: {MachineState.t(), Tracer.t()}
  def trace(bytecode, opts \\ []) do
    opts_with_tracer =
      opts |> Keyword.validate!(@execute_opts) |> Keyword.put(:tracer, Tracer.new())

    state = Interpreter.run(bytecode, opts_with_tracer)
    {state, state.tracer}
  end

  @doc "Returns the stack contents (top first). Deprecated: use `run/2` with `debug: true`."
  @deprecated "Use EEVM.run/2 with debug: true and read result.stack"
  @spec stack_values(MachineState.t()) :: [non_neg_integer()]
  def stack_values(state) do
    Stack.to_list(state.frame.stack)
  end

  @doc "Returns the logs emitted, in order. Deprecated: use `run/2` and read `result.logs`."
  @deprecated "Use EEVM.run/2 and read result.logs"
  @spec logs(MachineState.t()) :: [map()]
  def logs(%MachineState{} = state), do: Enum.reverse(state.substate.logs)

  @doc "Computes the logs bloom of the emitted logs. Deprecated: use `EEVM.Block.Bloom.from_logs/1`."
  @deprecated "Use EEVM.Block.Bloom.from_logs/1"
  @spec logs_bloom(MachineState.t()) :: Bloom.t()
  def logs_bloom(%MachineState{} = state) do
    Bloom.from_logs(state.substate.logs)
  end

  @doc """
  Disassembles bytecode into a human-readable list of instructions.

  ## Example

      iex> EEVM.disassemble(<<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>)
      [{0, "PUSH1", "0x01"}, {2, "PUSH1", "0x02"}, {4, "ADD", nil}, {5, "STOP", nil}]
  """
  @spec disassemble(binary()) :: [{non_neg_integer(), String.t(), String.t() | nil}]
  def disassemble(bytecode) do
    disassemble_loop(bytecode, 0, [])
  end

  defp disassemble_loop(bytecode, pc, acc) when pc < byte_size(bytecode) do
    opcode = :binary.at(bytecode, pc)

    case EEVM.Interpreter.Instructions.Registry.info(opcode) do
      {:ok, %{push_bytes: n} = info} ->
        # PUSH instruction — read the immediate bytes
        data =
          binary_part(
            bytecode,
            min(pc + 1, byte_size(bytecode)),
            min(n, byte_size(bytecode) - pc - 1)
          )

        hex = Base.encode16(data, case: :lower)
        disassemble_loop(bytecode, pc + 1 + n, [{pc, info.name, "0x" <> hex} | acc])

      {:ok, info} ->
        disassemble_loop(bytecode, pc + 1, [{pc, info.name, nil} | acc])

      {:error, _} ->
        disassemble_loop(bytecode, pc + 1, [
          {pc, "UNKNOWN(0x#{Integer.to_string(opcode, 16)})", nil} | acc
        ])
    end
  end

  defp disassemble_loop(_bytecode, _pc, acc) do
    Enum.reverse(acc)
  end
end
