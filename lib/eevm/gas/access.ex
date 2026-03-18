defmodule EEVM.Gas.Access do
  @moduledoc """
  Cold/warm storage access cost tracking per EIP-2929.

  EIP-2929 introduced the concept of "access lists" — sets of addresses and storage
  keys that have already been touched during the current transaction. The first access
  to an address or storage slot is "cold" (expensive), and subsequent accesses are
  "warm" (cheap).

  ## Cost Schedule (EIP-2929)

  | Access Type | Cold Cost | Warm Cost |
  |-------------|-----------|-----------|
  | Account (BALANCE, EXTCODESIZE, etc.) | 2,600 | 100 |
  | Storage slot (SLOAD) | 2,100 | 100 |

  This module tracks which addresses and storage keys have been accessed and returns
  the appropriate cost. The state's `accessed_addresses` and `accessed_storage_keys`
  MapSets are updated on each cold access.

  ## References

  - [EIP-2929: Gas cost increases for state access opcodes](https://eips.ethereum.org/EIPS/eip-2929)
  """

  alias EEVM.MachineState

  # EIP-2929: first access to an account address
  @cold_account_access_cost 2600
  # EIP-2929: subsequent access to any already-touched address or slot
  @warm_storage_read_cost 100
  # EIP-2929: first access to a storage slot
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
