defmodule EEVM.Opcodes.StackMemoryStorage do
  @moduledoc """
  Opcodes for stack manipulation, memory access, and persistent storage.

  ## EVM Concepts

  This module groups three closely related opcode categories:

  1. **Stack**: POP (0x50) discards the top element. It's used to clean up
     intermediate values left on the stack after a computation.

  2. **Memory**: MLOAD (0x51), MSTORE (0x52), MSTORE8 (0x53), and MSIZE (0x59)
     operate on the EVM's linear byte-addressable memory space. MLOAD and MSTORE
     always work in 32-byte (256-bit) words. MSTORE8 writes a single byte.
     Memory is volatile — it resets between calls. Accessing memory beyond its
     current bounds expands it automatically, which costs additional gas. The cost
     is quadratic, so very large memory accesses become increasingly expensive.

  3. **Storage**: SLOAD (0x54) and SSTORE (0x55) access the contract's persistent
     key-value store. Storage slots survive across transactions and are the most
     expensive read/write operations in the EVM — SSTORE costs 20,000 gas for a
     cold write. Storage maps uint256 keys to uint256 values.

  MSIZE (0x59) returns the size of the highest-accessed memory region, rounded up
  to the nearest 32-byte word.

  ## Elixir Learning Notes

  - Combining three related categories keeps the module focused without splitting
    into too many tiny files.
  - `with` chains express the "pop operands, do work, push result" pattern cleanly.
  - Pattern matching on opcode bytes in function heads dispatches directly without
    any conditional logic in function bodies.
  """

  alias EEVM.{Gas, MachineState, Memory, Stack, Storage}
  alias EEVM.Opcodes.Helpers

  # POP — discard the top of stack. No result is pushed.

  @doc """
  Dispatches a stack/memory/storage opcode to its implementation.

  Called by the executor for opcodes 0x50-0x55 and 0x59. Returns
  `{:ok, new_state}` on success or `{:error, reason, state}` on failure.
  An unrecognized opcode halts with `:invalid`.
  """
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}

  def execute(0x50, state) do
    case Stack.pop(state.stack) do
      {:ok, _value, new_stack} ->
        {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # MLOAD — read a 32-byte word from memory at `offset`.
  # Memory is zero-initialized, so reads beyond current bounds return 0.
  # The expansion cost is charged before the read — gas is deducted even if
  # the value turns out to be zero.

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

  # MSTORE — write a 32-byte big-endian word to memory at `offset`.
  # The EVM stores all values big-endian, so the MSB is at the lowest address.
  # Memory expansion is charged before the write.

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

  # MSTORE8 — write only the least significant byte of the stack value to memory.
  # Unlike MSTORE, this touches a single byte, so expansion cost covers just 1 byte.
  # Useful for building packed byte arrays without wasting 31 zero bytes.

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

  # SLOAD — read a 256-bit value from persistent storage by key.
  # Storage costs 200 gas (static, charged by the executor).
  # Unset keys return 0.

  def execute(0x54, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack),
         value = Storage.load(state.storage, key),
         {:ok, s2} <- Stack.push(s1, value) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SSTORE — write a 256-bit value to persistent storage.
  # This is one of the most expensive opcodes: 20,000 gas for a new slot, 2,900
  # to update an existing one (simplified here to static cost only).
  # Setting a slot to 0 deletes it and issues a gas refund in a full implementation.

  def execute(0x55, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      new_storage = Storage.store(state.storage, key, value)
      {:ok, %{state | stack: s2, storage: new_storage} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # MSIZE — return the size of the highest-accessed memory region.
  # The EVM tracks memory in 32-byte words, so MSIZE is always a multiple of 32.
  # Even a single byte access at offset 0 makes MSIZE return 32.

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
