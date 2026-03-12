defmodule EEVM.Opcodes.Crypto do
  @moduledoc """
  EVM cryptographic opcodes: KECCAK256.

  ## EVM Concepts

  KECCAK256 (opcode 0x20, formerly called SHA3 before standardization) hashes a
  region of memory and pushes the 256-bit hash onto the stack.

  It's one of the most frequently used opcodes in real contracts:

  - **Solidity mappings** — `mapping(key => value)` computes storage slots as
    `keccak256(abi.encode(key, slot_index))`.
  - **Event signatures** — `Transfer(address,address,uint256)` is identified by
    the first 4 bytes of `keccak256("Transfer(address,address,uint256)")`.
  - **CREATE2 addresses** — deterministic contract addresses use keccak256.

  Gas cost: 30 (static) + 6 per 32-byte word of input (dynamic).
  Memory expansion cost applies if the input range extends beyond current memory.

  ## Elixir Learning Notes

  - We use the `ExKeccak` NIF (native implemented function) for hashing.
    NIFs call into compiled C code, making them much faster than a pure Elixir
    implementation for cryptographic operations.
  - The binary pattern `<<hash_int::unsigned-big-256>>` decodes the raw 32-byte
    hash binary into a single 256-bit unsigned integer in one step.
  """
  alias EEVM.{MachineState, Memory, Stack}
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

      # Only charge memory expansion when there's actual input to read.
      # A zero-length hash still costs the static + dynamic gas, but reads
      # no memory and therefore never triggers expansion.
      mem_cost =
        if length > 0 do
          GasMemory.memory_expansion_cost(Memory.size(state.memory), offset, length)
        else
          0
        end

      case MachineState.consume_gas(state, dynamic_cost + mem_cost) do
        {:ok, state_after_gas} ->
          # Expand memory and read input bytes only when length > 0.
          # For length == 0 we hash an empty binary without touching memory.
          {data, updated_memory} =
            if length > 0 do
              Memory.read_bytes(state_after_gas.memory, offset, length)
            else
              {<<>>, state_after_gas.memory}
            end

          # ExKeccak.hash_256 returns a raw 32-byte binary. The pattern
          # `<<hash_int::unsigned-big-256>>` decodes it to a uint256 integer.
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
