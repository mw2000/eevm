defmodule EEVM.Executor do
  @moduledoc """
  The EVM execution engine — fetches, decodes, and dispatches opcodes.

  ## EVM Concepts

  The executor implements the EVM's fetch-decode-execute cycle:

  1. **Fetch**: Read one byte from bytecode at the current program counter.
  2. **Decode**: Look up the base gas cost and identify which opcode module
     handles this byte.
  3. **Execute**: Deduct base gas, delegate to the opcode module, and loop.

  Execution ends when:
  - A terminating opcode is reached (STOP, RETURN, REVERT, INVALID).
  - The program counter advances past the end of the bytecode (implicit STOP).
  - Gas runs out before the opcode can execute.

  INVALID (0xFE) is special-cased: its "base" gas cost is set to the entire
  remaining gas, draining it completely before the opcode runs.

  ## Elixir Learning Notes

  - `run_loop/1` is tail-recursive — Elixir optimizes tail calls, so the loop
    runs in constant stack space even for long-running contracts.
  - The three `run_loop/1` clauses use pattern matching on `status` to cleanly
    separate running, halted, and out-of-gas states without any conditionals.
  - `execute_opcode/2` is a private dispatch table. Specific opcodes come first,
    then ranges. Elixir matches clauses top-to-bottom, so narrower patterns
    must precede broader ones.
  - Separation of concerns: the executor only orchestrates; opcode modules own
    their semantics.
  """

  alias EEVM.{Gas, MachineState}

  alias EEVM.Opcodes.{
    Arithmetic,
    Bitwise,
    Comparison,
    ControlFlow,
    Crypto,
    Environment,
    StackMemoryStorage,
    System
  }

  @doc """
  Creates a `MachineState` from bytecode and options, then runs the execution loop.

  ## Options

  - `:gas` — initial gas limit (default: 1_000_000)
  - `:value` — ETH value sent with the call, in wei
  - `:code` — contract bytecode (usually the same as the first argument)
  - `:calldata` — ABI-encoded input data for the call
  - `:caller` — address of the account initiating this call
  - `:origin` — address of the original transaction signer

  Returns the final `MachineState` after execution completes.
  """

  @spec run(binary(), keyword()) :: MachineState.t()
  def run(code, opts \\ []) do
    code
    |> MachineState.new(opts)
    |> run_loop()
  end

  @doc """
  The main execution loop. Runs until execution terminates.

  Three clauses handle the three possible states:

  1. `status: :running` — fetch the current opcode, deduct static gas, delegate
     to `execute_opcode/2`, and recurse.
  2. Any non-running status (`:stopped`, `:returned`, `:reverted`, `:invalid`,
     `{:error, reason}`) — the machine has halted; return as-is.
  3. Out-of-gas during static cost deduction — the halted state is returned
     directly from `MachineState.consume_gas/2`.

  This function is public because it is called recursively by itself. It is
  the internal execution engine and not part of the public API — use `run/2`.
  """

  @spec run_loop(MachineState.t()) :: MachineState.t()
  def run_loop(%MachineState{status: :running} = state) do
    case MachineState.current_opcode(state) do
      nil ->
        MachineState.halt(state, :stopped)

      opcode ->
        static_cost = if opcode == 0xFE, do: state.gas, else: Gas.static_cost(opcode)

        case MachineState.consume_gas(state, static_cost) do
          {:ok, state_after_gas} ->
            case execute_opcode(opcode, state_after_gas) do
              {:ok, new_state} -> run_loop(new_state)
              {:error, :out_of_gas, halted_state} -> halted_state
              {:error, reason, error_state} -> MachineState.halt(error_state, {:error, reason})
            end

          {:error, :out_of_gas, halted_state} ->
            halted_state
        end
    end
  end

  def run_loop(state), do: state

  # Dispatch table for execute_opcode/2.
  #
  # Routes opcode bytes to the module that implements them. Specific opcodes
  # are listed first; ranges follow. This ordering matters — Elixir matches
  # clauses top-to-bottom, so e.g. 0x50 must appear before the 0x51..0x55
  # range to ensure it is caught by its dedicated StackMemoryStorage clause.
  # The fallback clause treats unknown opcodes as INVALID (halt, no gas refund).

  defp execute_opcode(0x00, state), do: System.execute(0x00, state)
  defp execute_opcode(op, state) when op in 0x01..0x0B, do: Arithmetic.execute(op, state)
  defp execute_opcode(op, state) when op in 0x10..0x15, do: Comparison.execute(op, state)
  defp execute_opcode(op, state) when op in 0x16..0x1D, do: Bitwise.execute(op, state)
  defp execute_opcode(0x20, state), do: Crypto.execute(0x20, state)
  defp execute_opcode(op, state) when op in 0x30..0x3D, do: Environment.execute(op, state)
  defp execute_opcode(op, state) when op in 0x40..0x48, do: Environment.execute(op, state)
  defp execute_opcode(0x50, state), do: StackMemoryStorage.execute(0x50, state)
  defp execute_opcode(op, state) when op in 0x51..0x55, do: StackMemoryStorage.execute(op, state)
  defp execute_opcode(0x59, state), do: StackMemoryStorage.execute(0x59, state)
  defp execute_opcode(0x5E, state), do: StackMemoryStorage.execute(0x5E, state)
  defp execute_opcode(0x5A, state), do: Environment.execute(0x5A, state)
  defp execute_opcode(op, state) when op in 0x56..0x5B, do: ControlFlow.execute(op, state)
  defp execute_opcode(0x5F, state), do: ControlFlow.execute(0x5F, state)
  defp execute_opcode(op, state) when op in 0x60..0x9F, do: ControlFlow.execute(op, state)
  defp execute_opcode(0xF3, state), do: System.execute(0xF3, state)
  defp execute_opcode(0xFD, state), do: System.execute(0xFD, state)
  defp execute_opcode(0xFE, state), do: System.execute(0xFE, state)
  defp execute_opcode(_op, state), do: {:ok, MachineState.halt(state, :invalid)}
end
