defmodule EEVM.Opcodes.Environment.External do
  @moduledoc false

  alias EEVM.{Gas, MachineState, Memory, Stack, WorldState}
  alias EEVM.Context.Contract
  alias EEVM.Opcodes.Helpers

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x31, state) do
    with {:ok, addr, s1} <- Stack.pop(state.stack),
         balance = lookup_balance(state, addr),
         {:ok, s2} <- Stack.push(s1, balance) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x3B, state) do
    with {:ok, addr, s1} <- Stack.pop(state.stack),
         size = byte_size(WorldState.get_code(state.world_state, addr)),
         {:ok, s2} <- Stack.push(s1, size) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x3C, state) do
    with {:ok, addr, s1} <- Stack.pop(state.stack),
         {:ok, dest_offset, s2} <- Stack.pop(s1),
         {:ok, code_offset, s3} <- Stack.pop(s2),
         {:ok, length, s4} <- Stack.pop(s3) do
      if length == 0 do
        {:ok, %{state | stack: s4} |> MachineState.advance_pc()}
      else
        dynamic_cost =
          Gas.copy_cost(length) +
            Gas.memory_expansion_cost(Memory.size(state.memory), dest_offset, length)

        case MachineState.consume_gas(%{state | stack: s4}, dynamic_cost) do
          {:ok, state_after_gas} ->
            bytes = read_external_code(state_after_gas.world_state, addr, code_offset, length)

            new_memory =
              bytes
              |> :binary.bin_to_list()
              |> Enum.with_index()
              |> Enum.reduce(state_after_gas.memory, fn {byte, i}, mem ->
                Memory.store_byte(mem, dest_offset + i, byte)
              end)

            {:ok, %{state_after_gas | memory: new_memory} |> MachineState.advance_pc()}

          {:error, :out_of_gas, halted_state} ->
            {:error, :out_of_gas, halted_state}
        end
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x3F, state) do
    with {:ok, addr, s1} <- Stack.pop(state.stack) do
      hash_value =
        if WorldState.account_exists?(state.world_state, addr) do
          code = WorldState.get_code(state.world_state, addr)
          hash = ExKeccak.hash_256(code)
          <<hash_int::unsigned-big-256>> = hash
          hash_int
        else
          0
        end

      with {:ok, s2} <- Stack.push(s1, hash_value) do
        {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
      else
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x47, state) do
    balance = lookup_balance(state, state.contract.address)
    Helpers.push_value(state, balance)
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}

  defp lookup_balance(state, address) do
    if WorldState.account_exists?(state.world_state, address) do
      WorldState.get_balance(state.world_state, address)
    else
      Contract.balance(state.contract, address)
    end
  end

  defp read_external_code(world_state, address, offset, length) do
    code = WorldState.get_code(world_state, address)
    code_size = byte_size(code)

    if offset >= code_size do
      <<0::size(length * 8)>>
    else
      available = min(length, code_size - offset)
      chunk = binary_part(code, offset, available)
      padding_size = (length - available) * 8
      <<chunk::binary, 0::size(padding_size)>>
    end
  end
end
