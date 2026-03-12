defmodule EEVM.Opcodes.StackMemoryStorage.MemoryOps do
  @moduledoc false

  alias EEVM.{Gas, MachineState, Memory, Stack}
  alias EEVM.Opcodes.Helpers

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x51, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         expansion_cost = Gas.memory_expansion_cost_word(Memory.size(state.memory), offset),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s1}, expansion_cost) do
      {value, new_memory} = Memory.load(state_after_gas.memory, offset)
      {:ok, s2} = Stack.push(state_after_gas.stack, value)
      {:ok, %{state_after_gas | stack: s2, memory: new_memory} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  def execute(0x52, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1),
         expansion_cost = Gas.memory_expansion_cost_word(Memory.size(state.memory), offset),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s2}, expansion_cost) do
      new_memory = Memory.store(state_after_gas.memory, offset, value)
      {:ok, %{state_after_gas | stack: s2, memory: new_memory} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  def execute(0x53, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1),
         expansion_cost = Gas.memory_expansion_cost_byte(Memory.size(state.memory), offset),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s2}, expansion_cost) do
      new_memory = Memory.store_byte(state_after_gas.memory, offset, value)
      {:ok, %{state_after_gas | stack: s2, memory: new_memory} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  def execute(0x59, state) do
    size = Memory.size(state.memory)
    Helpers.push_value(state, size)
  end

  def execute(0x5E, state) do
    with {:ok, dst, s1} <- Stack.pop(state.stack),
         {:ok, src, s2} <- Stack.pop(s1),
         {:ok, length, s3} <- Stack.pop(s2) do
      if length == 0 do
        {:ok, MachineState.advance_pc(%{state | stack: s3})}
      else
        max_offset = max(src + length, dst + length)
        expansion_cost = Gas.memory_expansion_cost(Memory.size(state.memory), 0, max_offset)
        dynamic_cost = Gas.copy_cost(length) + expansion_cost

        case MachineState.consume_gas(%{state | stack: s3}, dynamic_cost) do
          {:ok, s4} ->
            new_memory = Memory.copy(s4.memory, dst, src, length)
            {:ok, MachineState.advance_pc(%{s4 | memory: new_memory})}

          {:error, :out_of_gas, halted_state} ->
            {:error, :out_of_gas, halted_state}
        end
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
