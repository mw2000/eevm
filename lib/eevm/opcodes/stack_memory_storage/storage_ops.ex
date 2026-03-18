defmodule EEVM.Opcodes.StackMemoryStorage.StorageOps do
  @moduledoc false

  alias EEVM.{MachineState, Stack, Storage}
  alias EEVM.Gas.{Access, Dynamic}

  @cold_sload_cost 2100

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x54, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack) do
      contract_address = state.contract.address

      {access_cost, state_after_access} =
        Access.storage_access_cost(%{state | stack: s1}, contract_address, key)

      case MachineState.consume_gas(state_after_access, access_cost) do
        {:ok, state_after_gas} ->
          value = Storage.load(state_after_gas.storage, key)

          case Stack.push(state_after_gas.stack, value) do
            {:ok, s2} -> {:ok, %{state_after_gas | stack: s2} |> MachineState.advance_pc()}
            {:error, reason} -> {:error, reason, state_after_gas}
          end

        {:error, :out_of_gas, halted} ->
          {:error, :out_of_gas, halted}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x55, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      state_after_stack = %{state | stack: s2}
      contract_address = state_after_stack.contract.address
      access_key = {contract_address, key}
      is_warm = MapSet.member?(state_after_stack.accessed_storage_keys, access_key)

      state_after_access =
        if is_warm do
          state_after_stack
        else
          %{
            state_after_stack
            | accessed_storage_keys:
                MapSet.put(state_after_stack.accessed_storage_keys, access_key)
          }
        end

      cold_cost = if is_warm, do: 0, else: @cold_sload_cost
      {original_value, state_with_original} = get_original_value(state_after_access, key)
      current_value = Storage.load(state_with_original.storage, key)

      {sstore_gas, refund_delta} = Dynamic.sstore_cost(original_value, current_value, value)
      total_cost = cold_cost + sstore_gas

      case MachineState.consume_gas(state_with_original, total_cost) do
        {:ok, state_after_gas} ->
          state_after_refund = apply_refund_delta(state_after_gas, refund_delta)
          new_storage = Storage.store(state_after_refund.storage, key, value)
          {:ok, %{state_after_refund | storage: new_storage} |> MachineState.advance_pc()}

        {:error, :out_of_gas, halted} ->
          {:error, :out_of_gas, halted}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x5C, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack),
         value = Map.get(state.transient_storage, key, 0),
         {:ok, s2} <- Stack.push(s1, value) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x5D, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      new_transient = Map.put(state.transient_storage, key, value)
      {:ok, %{state | stack: s2, transient_storage: new_transient} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}

  defp get_original_value(state, key) do
    case Map.fetch(state.original_storage, key) do
      {:ok, value} ->
        {value, state}

      :error ->
        value = Storage.load(state.storage, key)
        {value, %{state | original_storage: Map.put(state.original_storage, key, value)}}
    end
  end

  defp apply_refund_delta(state, refund_delta) when refund_delta > 0,
    do: MachineState.add_refund(state, refund_delta)

  defp apply_refund_delta(state, refund_delta) when refund_delta < 0,
    do: MachineState.sub_refund(state, abs(refund_delta))

  defp apply_refund_delta(state, 0), do: state
end
