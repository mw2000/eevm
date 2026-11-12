defmodule EEVM do
  @moduledoc """
  EEVM — Ethereum Virtual Machine implementation in Elixir.

  Execution engine for every fork from Frontier to Osaka: full opcode set, all
  precompiles (BLS12-381 and KZG in pure Elixir), transaction validation and
  processing, whole blocks, and MPT-backed state roots. CI runs the official
  execution-spec-tests and `ethereum/tests` suites; the README's
  "Conformance" section lists the results and the known exceptions.

  ## Quick Start

      iex> {:ok, result} = EEVM.run(<<0x60, 2, 0x60, 3, 0x01, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xF3>>)
      iex> result.status
      :success
      iex> :binary.decode_unsigned(result.return_data)
      5

  ## Module Map

  The public API:

  - `EEVM` — run bytecode (`run/2`), call or deploy a contract without a
    signature (`call/4`, `create/3`), execute a signed transaction
    (`transact/4`), decode revert reasons, and the hashing and hex helpers
    that calls need (`keccak256/1`, `selector/1`, `event_topic/1`,
    `address/1`, `hex/1`)
  - `EEVM.ABI` — Solidity ABI encoding: calldata, return data, and event logs
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

  ## Errors

  A mistake in the arguments your own code passes, such as a hex string
  where `run/2`, `call/4`, or `create/3` take bytes, raises `ArgumentError`,
  while anything that can arrive from outside, such as the raw signed bytes
  `transact/4` takes, a block, or a database read, returns
  `{:error, reason}` with a reason listed in `EEVM.Error`.
  """

  alias EEVM.Block.Bloom

  alias EEVM.{
    ABI,
    BlockEnv,
    CallResult,
    Database,
    Handler,
    HardforkConfig,
    TransactionResult,
    TxEnv
  }

  alias EEVM.Context.Contract
  alias EEVM.Crypto.Keccak
  alias EEVM.Database.InMemory
  alias EEVM.Handler.{Execution, PostExecution, Validation}
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

  @message_opts [
    :config,
    :hardfork,
    :block,
    :tracer,
    gas: 30_000_000,
    caller: 0,
    value: 0,
    debug: false
  ]

  # Solidity's built-in revert payloads: Error(string) and Panic(uint256).
  @error_string_selector <<0x08, 0xC3, 0x79, 0xA0>>
  @panic_selector <<0x4E, 0x48, 0x7B, 0x71>>

  # EIP-3860 (Shanghai): the most initcode a contract creation may carry.
  @max_initcode_size 49_152

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
      CALLER, CALLVALUE, and the call's input (defaults `0`, `0`, `0`, `<<>>`).
      `:address` is required with `:db`: it is the account whose balance and
      storage the code sees. To call a contract already in `:db`, use
      `call/4`, which loads its code for you.
    - `:tracer` — `true` or an `EEVM.Tracer` to record an EIP-3155 trace,
      returned as `result.trace`
    - `:debug` — `true` to return the final stack as `result.stack`

  Any other option, or `:db` without `:address`, raises `ArgumentError`.

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
    refuse_hex!(code, "code")

    if Keyword.has_key?(opts, :db) and not Keyword.has_key?(opts, :address) do
      raise ArgumentError,
            "EEVM.run/2 got :db but no :address, so the code would see address 0's balance " <>
              "and storage. Pass :address, or use EEVM.call/4 to call a contract in the database"
    end

    opts = Keyword.validate!(opts, @run_opts)
    db = Keyword.get_lazy(opts, :db, &InMemory.new/0)

    contract =
      Contract.new(
        address: opts[:address],
        caller: opts[:caller],
        callvalue: opts[:value],
        calldata: refuse_hex!(opts[:calldata], "calldata")
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

      {:ok, call_result(state, db, opts)}
    end)
  end

  @doc """
  Calls the contract at address `to` with `calldata`, without a signed
  transaction: like `eth_call`, from any `:caller`.

  The code is loaded from `db`, following an EIP-7702 delegation, and runs
  as `to`, so it sees `to`'s balance and storage; a precompile address runs
  the precompile. `:value` moves from the caller to `to` first, and the
  addresses EIP-2929 starts warm (caller, `to`, precompiles, and from
  Shanghai the coinbase) are warm.

  No transaction rules apply: no signature, nonce, intrinsic gas, or fees.
  `result.gas_used` is execution gas only, without the 21,000 a transaction
  would add.

  ## Options

    - `:caller` — CALLER and ORIGIN (default `0`)
    - `:value` — wei sent with the call (default `0`)
    - `:gas` — the gas limit (default 30,000,000)
    - `:config` (or the `:hardfork` shorthand), `:block`, `:tracer`, and
      `:debug`, as for `run/2`

  Any other option raises `ArgumentError`.

  Returns `{:ok, %EEVM.CallResult{}}` however execution ends; check
  `result.status`, and see `revert_reason/1` for a revert. Nothing is
  committed: on success `result.db` holds the writes in its overlay, so pass
  it to the next call, or commit it with `EEVM.Database.commit/1`. Returns
  `{:error, :insufficient_balance}` when `:value` exceeds the caller's
  balance, or `{:error, {:database, reason}}` when the backend fails a read.

  ## Example

      iex> # Runtime code: return storage slot 0 as a word.
      iex> code = <<0x60, 0, 0x54, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xF3>>
      iex> db = EEVM.Database.InMemory.new(accounts: %{0xC0DE => %{code: code}}, storage: %{0xC0DE => %{0 => 42}})
      iex> {:ok, result} = EEVM.call(db, 0xC0DE, <<>>, caller: 0xA11CE)
      iex> {result.status, :binary.decode_unsigned(result.return_data)}
      {:success, 42}
  """
  @spec call(Database.t(), non_neg_integer(), binary(), keyword()) ::
          {:ok, CallResult.t()} | {:error, EEVM.Error.reason()}
  def call(%Database{} = db, to, calldata \\ <<>>, opts \\ [])
      when is_integer(to) and to >= 0 and to < @address_limit and is_binary(calldata) do
    message(db, to, refuse_hex!(calldata, "calldata"), opts)
  end

  @doc """
  Deploys a contract by running `initcode`, without a signed transaction:
  CREATE from any `:caller`.

  The caller's nonce is incremented and the new address derived from its
  value before the increment, as for a contract-creation transaction, so
  repeated deploys get new addresses. `:value` moves to the new account,
  the initcode runs there, and the code it returns is installed under the
  EIP-170 size limit, EIP-3541, and the code-deposit charge.
  `result.contract_address` is the new address, or `nil` when the
  deployment failed.

  Takes the same options as `call/4`, and like it applies no transaction
  rules and commits nothing: on success `result.db` holds the new account in
  its overlay; on failure it is `db` unchanged, nonce included. From
  Shanghai, initcode over 49,152 bytes returns `{:error, :initcode_too_large}`
  (EIP-3860).

  ## Example

      iex> # Initcode: copy the 11-byte runtime code from the call in `call/4`
      iex> # and return it.
      iex> runtime = <<0x60, 0, 0x54, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xF3>>
      iex> initcode = <<0x60, 11, 0x60, 12, 0x60, 0, 0x39, 0x60, 11, 0x60, 0, 0xF3>> <> runtime
      iex> {:ok, result} = EEVM.create(EEVM.Database.InMemory.new(), initcode, caller: 0xA11CE)
      iex> EEVM.Database.get_code(result.db, result.contract_address) == runtime
      true
  """
  @spec create(Database.t(), binary(), keyword()) ::
          {:ok, CallResult.t()} | {:error, EEVM.Error.reason()}
  def create(%Database{} = db, initcode, opts \\ []) when is_binary(initcode) do
    message(db, nil, refuse_hex!(initcode, "initcode"), opts)
  end

  defp message(db, to, data, opts) do
    opts = Keyword.validate!(opts, @message_opts)
    config = Validation.resolve_config(opts)
    block = Keyword.get_lazy(opts, :block, &BlockEnv.new/0)
    tx = %TxEnv{origin: opts[:caller], to: to, value: opts[:value], data: data}

    Database.catch_read_errors(fn ->
      with :ok <- check_message(db, tx, config) do
        # A creation bumps the caller's nonce first; Execution derives the
        # address from the nonce before the bump.
        db_ready = if to == nil, do: Database.increment_nonce(db, tx.origin), else: db

        {state, contract_address} =
          Execution.run_top_level(
            tx,
            db_ready,
            block,
            config,
            opts[:gas],
            %{authorities: MapSet.new(), refund: 0},
            Validation.resolve_tracer(opts)
          )

        {:ok, %{call_result(state, db, opts) | contract_address: contract_address}}
      end
    end)
  end

  defp check_message(db, %TxEnv{} = tx, config) do
    cond do
      Database.get_balance(db, tx.origin) < tx.value ->
        {:error, :insufficient_balance}

      tx.to == nil and byte_size(tx.data) > @max_initcode_size and
          HardforkConfig.enabled?(config.hardfork, :eip_3860) ->
        {:error, :initcode_too_large}

      true ->
        :ok
    end
  end

  # Code and calldata are bytes. A `0x`-prefixed hex string is almost surely
  # a mistake: run as code, its ASCII would execute as ADDRESS, PUSH25, ...
  defp refuse_hex!(data, what) do
    if hex_string?(data) do
      raise ArgumentError,
            "#{what} is a hex string (#{inspect(data, printable_limit: 40)}), not bytes; " <>
              "decode it with EEVM.bytes/1"
    end

    data
  end

  @doc false
  # Whether `data` is a `0x`-prefixed hex string rather than raw bytes.
  @spec hex_string?(binary()) :: boolean()
  def hex_string?(<<"0x", digits::binary>>), do: hex_digits?(digits)
  def hex_string?(_data), do: false

  defp hex_digits?(<<c, rest::binary>>) when c in ?0..?9 or c in ?a..?f or c in ?A..?F,
    do: hex_digits?(rest)

  defp hex_digits?(<<>>), do: true
  defp hex_digits?(_data), do: false

  # The result of a message call; on failure the database is `db_before`.
  defp call_result(state, db_before, opts) do
    status = PostExecution.status(state.status)
    db_after = if status == :success, do: state.db, else: db_before

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
    }
  end

  @doc """
  Validates and executes one signed transaction against `db` in the block
  environment `block`: decode, recover the sender, validate, charge gas,
  execute, refund, and pay the coinbase.

  `tx` is a transaction struct (see `EEVM.Transaction`) or its raw signed
  bytes. Options are `:config` (or the `:hardfork` shorthand) and `:tracer`,
  as for `run/2`, and `details: true`, which returns a rejection as
  `{:error, %EEVM.TransactionError{}}` with the values involved, such as
  the transaction's and the account's nonce.

  Returns `{:ok, %EEVM.TransactionResult{}}` for any transaction that passes
  validation, including reverted and halted ones, or `{:error, reason}` with
  a reason from `EEVM.Error`, leaving `db` unchanged.

  ## Example

      iex> tx = %EEVM.Transaction.Legacy{nonce: 5, gas_price: 10, gas_limit: 21_000, to: 0xB0B}
      iex> {:ok, tx} = EEVM.Transaction.Signer.sign(tx, <<0x46::256>>, EEVM.Config.new(:cancun))
      iex> db = EEVM.Database.InMemory.new()
      iex> EEVM.transact(tx, EEVM.BlockEnv.new(), db)
      {:error, :nonce_too_high}
      iex> {:error, error} = EEVM.transact(tx, EEVM.BlockEnv.new(), db, details: true)
      iex> {error.reason, error.details.tx_nonce, error.details.state_nonce}
      {:nonce_too_high, 5, 0}
  """
  @spec transact(Handler.wire_tx(), BlockEnv.t(), Database.t(), Handler.opts()) ::
          {:ok, TransactionResult.t()}
          | {:error, EEVM.Error.reason() | EEVM.TransactionError.t()}
  defdelegate transact(tx, block, db, opts \\ []), to: Handler, as: :execute

  @doc """
  Decodes why a call reverted, from its REVERT data or from an
  `EEVM.CallResult` or `EEVM.TransactionResult`.

  Returns:

    - `{:error_string, message}` for Solidity's `Error(string)`
      (selector `0x08c379a0`), what `require(cond, "message")` and
      `revert("message")` produce
    - `{:panic, code}` for `Panic(uint256)` (selector `0x4e487b71`), such
      as `0x01` for a failed `assert`, `0x11` for arithmetic overflow, and
      `0x12` for division by zero
    - `{:custom, selector, args}` for any other payload of four bytes or
      more, such as a Solidity custom error (decode its `args` with
      `EEVM.ABI.decode/2`) or a malformed `Error(string)`
    - `{:raw, data}` for one to three bytes
    - `nil` for no data, or for a result whose `status` isn't `:revert`

  ## Examples

      iex> data = EEVM.ABI.encode_call("Error(string)", ["nope!"])
      iex> EEVM.revert_reason(data)
      {:error_string, "nope!"}

      iex> EEVM.revert_reason(<<0x4E487B71::32, 0x12::256>>)
      {:panic, 0x12}

      iex> {:ok, result} = EEVM.run(<<0x60, 0, 0x60, 0, 0xFD>>)
      iex> {result.status, EEVM.revert_reason(result)}
      {:revert, nil}
  """
  @spec revert_reason(binary() | CallResult.t() | TransactionResult.t()) ::
          {:error_string, String.t()}
          | {:panic, non_neg_integer()}
          | {:custom, <<_::32>>, binary()}
          | {:raw, binary()}
          | nil
  def revert_reason(%CallResult{status: :revert, return_data: data}), do: revert_reason(data)

  def revert_reason(%TransactionResult{status: :revert, return_data: data}),
    do: revert_reason(data)

  def revert_reason(%CallResult{}), do: nil
  def revert_reason(%TransactionResult{}), do: nil
  def revert_reason(<<>>), do: nil
  def revert_reason(<<@panic_selector, code::256>>), do: {:panic, code}

  def revert_reason(<<@error_string_selector, args::binary>> = data) do
    case ABI.decode(["string"], args) do
      {:ok, [message]} -> {:error_string, message}
      {:error, :invalid_abi_data} -> revert_reason_custom(data)
    end
  end

  def revert_reason(data) when is_binary(data), do: revert_reason_custom(data)

  defp revert_reason_custom(<<selector::binary-size(4), args::binary>>),
    do: {:custom, selector, args}

  defp revert_reason_custom(data), do: {:raw, data}

  @doc """
  Returns the 32-byte Keccak-256 hash of `data`, Ethereum's hash function
  (the original Keccak padding, not NIST SHA3-256).

  ## Example

      iex> EEVM.keccak256("") |> EEVM.hex()
      "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
  """
  @spec keccak256(binary()) :: <<_::256>>
  def keccak256(data) when is_binary(data), do: Keccak.hash_256(data)

  @doc """
  Returns the 4-byte ABI selector of a function signature: the first four
  bytes of its Keccak-256 hash. Write the signature in canonical form, with
  no spaces or parameter names and full type names (`uint256`, not `uint`).

  Prepend it to the ABI-encoded arguments to build calldata, or let
  `EEVM.ABI.encode_call/2` do both.

  ## Example

      iex> EEVM.selector("transfer(address,uint256)")
      <<0xA9, 0x05, 0x9C, 0xBB>>
  """
  @spec selector(String.t()) :: <<_::32>>
  def selector(signature) when is_binary(signature),
    do: binary_part(Keccak.hash_256(signature), 0, 4)

  @doc """
  Returns the first log topic of an event signature, its Keccak-256 hash, as
  an integer, which is how `result.logs` carries topics. Anonymous events
  have no such topic. `EEVM.ABI.decode_log/2` matches and decodes a whole log.

  ## Example

      iex> EEVM.event_topic("Transfer(address,address,uint256)") |> EEVM.hex()
      "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  """
  @spec event_topic(String.t()) :: non_neg_integer()
  def event_topic(signature) when is_binary(signature) do
    <<topic::unsigned-big-256>> = Keccak.hash_256(signature)
    topic
  end

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
  Decodes a hex string, with or without `0x` and in any case, into bytes:
  the inverse of `hex/1` for binaries. Use it on bytecode, calldata, or raw
  transactions copied from a compiler, explorer, or wallet; `run/2`,
  `call/4`, `create/3`, and `transact/4` take bytes and reject
  `0x`-prefixed hex strings.

  Raises `ArgumentError` for anything that isn't an even number of hex
  digits.

  ## Examples

      iex> EEVM.bytes("0x6002600301")
      <<0x60, 0x02, 0x60, 0x03, 0x01>>
      iex> EEVM.bytes("ABcd")
      <<0xAB, 0xCD>>
      iex> EEVM.bytes("0x")
      ""
  """
  @spec bytes(String.t()) :: binary()
  def bytes(<<prefix::binary-size(2), digits::binary>>) when prefix in ["0x", "0X"],
    do: decode_hex!(digits)

  def bytes(hex) when is_binary(hex), do: decode_hex!(hex)

  defp decode_hex!(digits) do
    case Base.decode16(digits, case: :mixed) do
      {:ok, bytes} -> bytes
      :error -> raise ArgumentError, "not a hex string: #{inspect(digits, printable_limit: 80)}"
    end
  end

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
