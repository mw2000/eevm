defmodule EEVM do
  @moduledoc """
  EEVM — Ethereum Virtual Machine implementation in Elixir.

  Execution engine for every fork from Frontier to Osaka (Osaka in
  progress): full opcode set, all precompiles (including BLS12-381 via NIF),
  transaction validation and processing, whole blocks, MPT-backed state root,
  and harnesses for the official `ethereum/tests` suites. Conformance with
  those suites is still in progress.

  ## Quick Start

      iex> result = EEVM.execute(<<0x60, 2, 0x60, 3, 0x01, 0x00>>)
      iex> result.status
      :stopped
      iex> EEVM.stack_values(result)
      [5]

  ## Module Map

  The public API:

  - `EEVM` — run raw bytecode (`execute/2`, `trace/2`) and disassemble it
  - `EEVM.Config` and `EEVM.HardforkConfig` — the hardfork and custom precompiles
  - `EEVM.Error` — every error reason
  - `EEVM.Handler` — validate and execute one signed transaction
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
  alias EEVM.Interpreter
  alias EEVM.Interpreter.{MachineState, Stack}
  alias EEVM.Tracer

  @execute_opts [:gas, :hardfork, :config, :db, :block, :tx, :contract]

  @doc """
  Executes EVM bytecode and returns the final machine state.

  ## Options

    - `:gas` — initial gas limit (default: 1,000,000)
    - `:hardfork` — hardfork spec id (default `:cancun`), or `:config` for a
      full `EEVM.Config`
    - `:db` — the `EEVM.Database` to run against (default: an empty
      `EEVM.Database.InMemory`)
    - `:block` and `:tx` — the `EEVM.Context.Block` and
      `EEVM.Context.Transaction` the code sees
    - `:contract` — the `EEVM.Context.Contract` being executed: its address,
      caller, call value, and calldata

  Any other option raises `ArgumentError`.

  ## Example

      iex> result = EEVM.execute(<<0x60, 0x0A, 0x60, 0x14, 0x01, 0x00>>)
      iex> EEVM.stack_values(result)
      [30]
  """
  @spec execute(binary(), keyword()) :: EEVM.Interpreter.MachineState.t()
  def execute(bytecode, opts \\ []) do
    Interpreter.run(bytecode, Keyword.validate!(opts, @execute_opts))
  end

  @doc """
  Executes bytecode with an opcode-level tracer attached.

  Returns `{final_state, tracer}`. The tracer holds one `TraceStep` per
  executed opcode (see `EEVM.Tracer`). Use `EEVM.Tracer.to_json/1` to emit
  a trace in EIP-3155 / geth `--json` format. Takes the options of
  `execute/2`.

  ## Example

      iex> {state, tracer} = EEVM.trace(<<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>)
      iex> state.status
      :stopped
      iex> length(EEVM.Tracer.steps(tracer))
      4
  """
  @spec trace(binary(), keyword()) :: {MachineState.t(), Tracer.t()}
  def trace(bytecode, opts \\ []) do
    opts_with_tracer =
      opts |> Keyword.validate!(@execute_opts) |> Keyword.put(:tracer, Tracer.new())

    state = Interpreter.run(bytecode, opts_with_tracer)
    {state, state.tracer}
  end

  @doc """
  Returns the stack contents as a list (top first).

  Convenience wrapper for inspecting results.
  """
  @spec stack_values(EEVM.Interpreter.MachineState.t()) :: [non_neg_integer()]
  def stack_values(state) do
    Stack.to_list(state.frame.stack)
  end

  @doc "Returns the logs emitted during execution, in emission order."
  @spec logs(MachineState.t()) :: [map()]
  def logs(%MachineState{} = state), do: Enum.reverse(state.substate.logs)

  @doc "Computes the 256-byte logs bloom filter for the executed transaction."
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
