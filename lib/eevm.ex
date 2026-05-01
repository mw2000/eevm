defmodule EEVM do
  @moduledoc """
  EEVM — Ethereum Virtual Machine implementation in Elixir.

  Hardfork-aware execution engine covering Frontier through Prague: full
  opcode set, all precompiles (including BLS12-381 via NIF), transaction
  validation and processing, MPT-backed state root, and a harness for the
  official `ethereum/tests` `GeneralStateTests` suite.

  ## Quick Start

      iex> result = EEVM.execute(<<0x60, 2, 0x60, 3, 0x01, 0x00>>)
      iex> result.status
      :stopped
      iex> EEVM.stack_values(result)
      [5]

  ## Module Map

  - `EEVM.Interpreter` — fetch-decode-execute loop and call frames
  - `EEVM.Interpreter.MachineState` — frame-local state (pc, stack, memory, gas)
  - `EEVM.Precompiles` — registered precompiles (`0x01`–`0x11`)
  - `EEVM.Transaction` — envelope decoding, validation, signing, intrinsic gas
  - `EEVM.Block.Processor` — end-to-end transaction-to-receipt pipeline
  - `EEVM.Database`, `EEVM.WorldState`, `EEVM.Storage` — account and storage state
  - `EEVM.MPT.Trie` + `EEVM.StateRoot` — Merkle-Patricia trie and state-root hash
  - `EEVM.HardforkConfig` — per-hardfork EIP activation flags
  - `EEVM.SystemContracts` — EIP-2935 (block hashes) and EIP-4788 (beacon roots)
  """

  alias EEVM.Block.Bloom
  alias EEVM.Interpreter
  alias EEVM.Interpreter.{MachineState, Stack}
  alias EEVM.Tracer

  @doc """
  Executes EVM bytecode and returns the final machine state.

  ## Options
    - `:gas` — initial gas limit (default: 1,000,000)

  ## Example

      iex> result = EEVM.execute(<<0x60, 0x0A, 0x60, 0x14, 0x01, 0x00>>)
      iex> EEVM.stack_values(result)
      [30]
  """
  @spec execute(binary(), keyword()) :: EEVM.Interpreter.MachineState.t()
  def execute(bytecode, opts \\ []) do
    Interpreter.run(bytecode, opts)
  end

  @doc """
  Executes bytecode with an opcode-level tracer attached.

  Returns `{final_state, tracer}`. The tracer holds one `TraceStep` per
  executed opcode (see `EEVM.Tracer`). Use `EEVM.Tracer.to_json/1` to emit
  a trace in EIP-3155 / geth `--json` format.

  ## Example

      iex> {state, tracer} = EEVM.trace(<<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>)
      iex> state.status
      :stopped
      iex> length(EEVM.Tracer.steps(tracer))
      4
  """
  @spec trace(binary(), keyword()) :: {MachineState.t(), Tracer.t()}
  def trace(bytecode, opts \\ []) do
    opts_with_tracer = Keyword.put(opts, :tracer, Tracer.new())
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

  @doc "Returns the list of logs emitted during execution."
  @spec logs(MachineState.t()) :: [map()]
  def logs(%MachineState{} = state), do: state.substate.logs

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
