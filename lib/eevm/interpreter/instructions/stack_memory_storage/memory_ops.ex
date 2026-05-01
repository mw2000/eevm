defmodule EEVM.Interpreter.Instructions.StackMemoryStorage.MemoryOps do
  @moduledoc """
  Memory access opcodes: MLOAD, MSTORE, MSTORE8, MSIZE, and MCOPY.

  These opcodes read from and write to EVM linear memory. Memory is byte-addressable
  and expands on demand — each expansion incurs a gas cost calculated by `Gas.Memory`.

  - **MLOAD** (0x51) — loads a 32-byte word from memory at the given offset.
  - **MSTORE** (0x52) — stores a 32-byte word to memory at the given offset.
  - **MSTORE8** (0x53) — stores a single byte (lowest byte of value) at the given offset.
  - **MSIZE** (0x59) — pushes the current memory size in bytes.
  - **MCOPY** (0x5E) — copies a region of memory to another location (EIP-5656).
  """

  alias EEVM.Gas.Dynamic
  alias EEVM.Gas.Memory, as: GasMemory
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.Instructions.Helpers
  alias EEVM.Interpreter.{MachineState, Memory, Stack}

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x51, state) do
    with {:ok, offset, s1} <- Stack.pop(state.frame.stack),
         expansion_cost =
           GasMemory.memory_expansion_cost_word(Memory.size(state.frame.memory), offset),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(
             MachineState.update_frame(state, &%{&1 | stack: s1}),
             expansion_cost
           ) do
      {value, new_memory} = Memory.load(state_after_gas.frame.memory, offset)
      {:ok, s2} = Stack.push(state_after_gas.frame.stack, value)

      {:ok,
       state_after_gas
       |> MachineState.update_frame(&%{&1 | stack: s2, memory: new_memory})
       |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  def execute(0x52, state) do
    with {:ok, offset, s1} <- Stack.pop(state.frame.stack),
         {:ok, value, s2} <- Stack.pop(s1),
         expansion_cost =
           GasMemory.memory_expansion_cost_word(Memory.size(state.frame.memory), offset),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(
             MachineState.update_frame(state, &%{&1 | stack: s2}),
             expansion_cost
           ) do
      new_memory = Memory.store(state_after_gas.frame.memory, offset, value)

      {:ok,
       state_after_gas
       |> MachineState.update_frame(&%{&1 | stack: s2, memory: new_memory})
       |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  def execute(0x53, state) do
    with {:ok, offset, s1} <- Stack.pop(state.frame.stack),
         {:ok, value, s2} <- Stack.pop(s1),
         expansion_cost =
           GasMemory.memory_expansion_cost_byte(Memory.size(state.frame.memory), offset),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(
             MachineState.update_frame(state, &%{&1 | stack: s2}),
             expansion_cost
           ) do
      new_memory = Memory.store_byte(state_after_gas.frame.memory, offset, value)

      {:ok,
       state_after_gas
       |> MachineState.update_frame(&%{&1 | stack: s2, memory: new_memory})
       |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  def execute(0x59, state) do
    size = Memory.size(state.frame.memory)
    Helpers.push_value(state, size)
  end

  # MCOPY (EIP-5656, Cancun+): copies a region of memory to another location.
  # Pre-Cancun, 0x5E is undefined → :invalid.
  def execute(0x5E, %{env: %{config: %{hardfork: hardfork}}} = state) do
    if HardforkConfig.enabled?(hardfork, :eip_5656) do
      with {:ok, dst, s1} <- Stack.pop(state.frame.stack),
           {:ok, src, s2} <- Stack.pop(s1),
           {:ok, length, s3} <- Stack.pop(s2) do
        if length == 0 do
          {:ok,
           state
           |> MachineState.update_frame(&%{&1 | stack: s3})
           |> MachineState.advance_pc()}
        else
          max_offset = max(src + length, dst + length)

          expansion_cost =
            GasMemory.memory_expansion_cost(Memory.size(state.frame.memory), 0, max_offset)

          dynamic_cost = Dynamic.copy_cost(length) + expansion_cost

          case MachineState.consume_gas(
                 MachineState.update_frame(state, &%{&1 | stack: s3}),
                 dynamic_cost
               ) do
            {:ok, s4} ->
              new_memory = Memory.copy(s4.frame.memory, dst, src, length)

              {:ok,
               s4
               |> MachineState.update_frame(&%{&1 | memory: new_memory})
               |> MachineState.advance_pc()}

            {:error, :out_of_gas, halted_state} ->
              {:error, :out_of_gas, halted_state}
          end
        end
      else
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:ok, MachineState.halt(state, :invalid)}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
