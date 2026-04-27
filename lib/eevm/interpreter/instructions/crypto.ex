defmodule EEVM.Interpreter.Instructions.Crypto do
  @moduledoc """
  KECCAK256 (0x20).

  Hashes a memory range and pushes the digest as a uint256. Gas is 30 +
  6/word dynamic plus memory expansion. Length-0 input is valid and hashes
  the empty string without touching memory. Backed by the `ExKeccak` NIF.
  """
  alias EEVM.Interpreter.{MachineState, Memory, Stack}
  alias EEVM.Gas.Dynamic
  alias EEVM.Gas.Memory, as: GasMemory

  @doc """
  Hashes a region of memory with Keccak-256 and pushes the result.

  Pops `offset` and `length` from the stack, reads `length` bytes of memory
  starting at `offset`, and pushes the 32-byte Keccak-256 hash as a uint256.
  An empty input (length == 0) is valid and returns the hash of the empty string.

  Gas: 30 (static) + 6 per word (dynamic) + memory expansion cost if applicable.
  """
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x20, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, length, s2} <- Stack.pop(s1) do
      dynamic_cost = Dynamic.keccak256_dynamic_cost(length)

      mem_cost =
        if length > 0 do
          GasMemory.memory_expansion_cost(Memory.size(state.memory), offset, length)
        else
          0
        end

      case MachineState.consume_gas(state, dynamic_cost + mem_cost) do
        {:ok, state_after_gas} ->
          {data, updated_memory} =
            if length > 0 do
              Memory.read_bytes(state_after_gas.memory, offset, length)
            else
              {<<>>, state_after_gas.memory}
            end

          hash = ExKeccak.hash_256(data)
          <<hash_int::unsigned-big-256>> = hash
          {:ok, new_stack} = Stack.push(s2, hash_int)

          {:ok,
           %{state_after_gas | stack: new_stack, memory: updated_memory}
           |> MachineState.advance_pc()}

        {:error, :out_of_gas, halted} ->
          {:error, :out_of_gas, halted}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
