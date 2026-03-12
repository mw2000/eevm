defmodule EEVM.Opcodes.Environment.Data do
  @moduledoc false

  alias EEVM.{Gas, MachineState, Memory, Stack}
  alias EEVM.Context.Contract

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x35, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         value = Contract.calldata_load(state.contract, offset),
         {:ok, s2} <- Stack.push(s1, value) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x37, state) do
    with {:ok, dest_offset, s1} <- Stack.pop(state.stack),
         {:ok, data_offset, s2} <- Stack.pop(s1),
         {:ok, length, s3} <- Stack.pop(s2) do
      if length == 0 do
        {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
      else
        expansion_cost = Gas.memory_expansion_cost(Memory.size(state.memory), dest_offset, length)

        case MachineState.consume_gas(%{state | stack: s3}, expansion_cost) do
          {:ok, state_after_gas} ->
            calldata = state_after_gas.contract.calldata
            cd_size = byte_size(calldata)

            bytes =
              for i <- 0..(length - 1), into: <<>> do
                if data_offset + i < cd_size do
                  <<:binary.at(calldata, data_offset + i)>>
                else
                  <<0>>
                end
              end

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

  def execute(0x39, state) do
    with {:ok, dest_offset, s1} <- Stack.pop(state.stack),
         {:ok, code_offset, s2} <- Stack.pop(s1),
         {:ok, length, s3} <- Stack.pop(s2) do
      if length == 0 do
        {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
      else
        dynamic_cost =
          Gas.copy_cost(length) +
            Gas.memory_expansion_cost(Memory.size(state.memory), dest_offset, length)

        case MachineState.consume_gas(%{state | stack: s3}, dynamic_cost) do
          {:ok, state_after_gas} ->
            bytes = MachineState.read_code(state_after_gas, code_offset, length)

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

  def execute(0x3E, state) do
    with {:ok, dest_offset, s1} <- Stack.pop(state.stack),
         {:ok, data_offset, s2} <- Stack.pop(s1),
         {:ok, length, s3} <- Stack.pop(s2) do
      cond do
        length == 0 ->
          {:ok, MachineState.advance_pc(%{state | stack: s3})}

        data_offset + length > byte_size(state.return_data) ->
          {:ok, MachineState.halt(%{state | stack: s3}, :reverted)}

        true ->
          dynamic_cost =
            Gas.copy_cost(length) +
              Gas.memory_expansion_cost(Memory.size(state.memory), dest_offset, length)

          case MachineState.consume_gas(%{state | stack: s3}, dynamic_cost) do
            {:ok, s4} ->
              bytes = binary_part(s4.return_data, data_offset, length)

              new_memory =
                bytes
                |> :binary.bin_to_list()
                |> Enum.with_index()
                |> Enum.reduce(s4.memory, fn {byte, i}, mem ->
                  Memory.store_byte(mem, dest_offset + i, byte)
                end)

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
