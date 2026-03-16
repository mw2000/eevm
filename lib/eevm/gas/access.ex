defmodule EEVM.Gas.Access do
  @moduledoc false

  alias EEVM.MachineState

  @cold_account_access_cost 2600
  @warm_storage_read_cost 100
  @cold_sload_cost 2100

  @spec address_access_cost(MachineState.t(), non_neg_integer()) ::
          {non_neg_integer(), MachineState.t()}
  def address_access_cost(state, address) do
    if MapSet.member?(state.accessed_addresses, address) do
      {@warm_storage_read_cost, state}
    else
      new_state = %{state | accessed_addresses: MapSet.put(state.accessed_addresses, address)}
      {@cold_account_access_cost, new_state}
    end
  end

  @spec storage_access_cost(MachineState.t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), MachineState.t()}
  def storage_access_cost(state, address, slot) do
    key = {address, slot}

    if MapSet.member?(state.accessed_storage_keys, key) do
      {@warm_storage_read_cost, state}
    else
      new_state = %{state | accessed_storage_keys: MapSet.put(state.accessed_storage_keys, key)}
      {@cold_sload_cost, new_state}
    end
  end

  @spec warm_address?(MachineState.t(), non_neg_integer()) :: boolean()
  def warm_address?(state, address), do: MapSet.member?(state.accessed_addresses, address)

  @spec mark_address_warm(MachineState.t(), non_neg_integer()) :: MachineState.t()
  def mark_address_warm(state, address) do
    %{state | accessed_addresses: MapSet.put(state.accessed_addresses, address)}
  end
end
