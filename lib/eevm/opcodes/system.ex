defmodule EEVM.Opcodes.System do
  @moduledoc """
  Opcodes that terminate execution.

  ## EVM Concepts

  Every EVM execution must end with a terminating opcode. This module
  implements all four:

  - **STOP (0x00)**: Normal termination with no return data. The cheapest
    way to end a call.

  - **RETURN (0xF3)**: Normal termination with return data. Pops a memory
    offset and length, reads that slice from memory, and sets it as the
    return data for the caller. Successful — state changes are kept.

  - **REVERT (0xFD)**: Abnormal termination with return data. Same memory
    slice semantics as RETURN, but all state changes made during this call
    are rolled back. Commonly used to return ABI-encoded error data.

  - **INVALID (0xFE)**: Unconditional failure. Consumes all remaining gas
    and rolls back state. Solidity uses it as an unreachable marker — if
    execution reaches INVALID, something went seriously wrong.

  The key distinction: RETURN and REVERT both produce output data and can
  read from memory. The difference is only in the status code — `:stopped`
  vs `:reverted`. STOP and INVALID produce no output.

  ## Elixir Learning Notes

  - Status atoms (`:stopped`, `:reverted`, `:invalid`) passed to
    `MachineState.halt/2` let the executor and caller distinguish outcomes
    without pattern matching on error tuples.
  - RETURN and REVERT share identical structure — only the halt status atom
    differs. This highlights how small Elixir expressions can encode
    meaningful semantic differences.
  """

  alias EEVM.{Gas, MachineState, Memory, Stack}

  @doc """
  Dispatches a system opcode to its implementation.

  Called by the executor for STOP (0x00), RETURN (0xF3), REVERT (0xFD), and
  INVALID (0xFE). Always returns `{:ok, new_state}` with a halted
  `MachineState`. The status field on the returned state indicates how
  execution ended.
  """
  @spec execute(non_neg_integer(), MachineState.t()) :: {:ok, MachineState.t()}

  # STOP — halt immediately. No stack interaction, no return data.

  def execute(0x00, state), do: {:ok, MachineState.halt(state, :stopped)}

  # RETURN — halt successfully and expose a memory slice as return data.
  # offset/length pop from the stack define the memory range to read.
  # Memory may expand to cover the range, which costs expansion gas.

  def execute(0xF3, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, length, s2} <- Stack.pop(s1),
         expansion_cost = Gas.memory_expansion_cost(Memory.size(state.memory), offset, length),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s2}, expansion_cost) do
      {return_data, new_memory} = Memory.read_bytes(state_after_gas.memory, offset, length)

      {:ok,
       %{state_after_gas | stack: s2, memory: new_memory, return_data: return_data}
       |> MachineState.halt(:stopped)}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  # REVERT — identical memory semantics to RETURN, but the halt status is
  # :reverted. The caller sees this as a failed sub-call and rolls back any
  # storage or balance changes made during this execution.

  def execute(0xFD, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, length, s2} <- Stack.pop(s1),
         expansion_cost = Gas.memory_expansion_cost(Memory.size(state.memory), offset, length),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s2}, expansion_cost) do
      {return_data, new_memory} = Memory.read_bytes(state_after_gas.memory, offset, length)

      {:ok,
       %{state_after_gas | stack: s2, memory: new_memory, return_data: return_data}
       |> MachineState.halt(:reverted)}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  # INVALID — marks an unreachable code path. Consumes all remaining gas.
  # The executor special-cases 0xFE to set static_cost = state.gas before
  # calling here, so gas is already drained by the time execute/2 runs.

  def execute(0xFE, state), do: {:ok, MachineState.halt(state, :invalid)}
  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
