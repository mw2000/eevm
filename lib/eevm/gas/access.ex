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
  | Account (CALL family, on top of its static 100) | +2,500 | +0 |
  | Storage slot (SLOAD) | 2,100 | 100 |
  | Storage slot (SSTORE, on top of its schedule) | +2,100 | +0 |

  This module tracks which addresses and storage keys have been accessed and returns
  the appropriate cost. The state's `accessed_addresses` and `accessed_storage_keys`
  MapSets are updated on each cold access.

  Before Berlin there is no warm/cold distinction: the opcodes' flat static
  costs (`EEVM.Gas.Static.static_cost/2`) cover the access, so these functions
  charge nothing.

  ## References

  - [EIP-2929: Gas cost increases for state access opcodes](https://eips.ethereum.org/EIPS/eip-2929)
  """

  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.MachineState

  # EIP-2929: first access to an account address
  @cold_account_access_cost 2600
  # EIP-2929: subsequent access to any already-touched address or slot
  @warm_storage_read_cost 100
  # EIP-2929: first access to a storage slot
  @cold_sload_cost 2100

  @doc """
  Access cost of an account-reading opcode (BALANCE, EXTCODESIZE,
  EXTCODECOPY, EXTCODEHASH), whose static cost is 0 from Berlin on:
  2,600 cold, 100 warm. Marks `address` warm.
  """
  @spec address_access_cost(MachineState.t(), non_neg_integer()) ::
          {non_neg_integer(), MachineState.t()}
  def address_access_cost(state, address),
    do: account_cost(state, address, @warm_storage_read_cost, @cold_account_access_cost)

  @doc """
  Extra access cost of a CALL-family target. Their static cost already
  includes the warm price (100), so a cold target adds 2,500. Marks
  `address` warm.
  """
  @spec call_access_cost(MachineState.t(), non_neg_integer()) ::
          {non_neg_integer(), MachineState.t()}
  def call_access_cost(state, address),
    do: account_cost(state, address, 0, @cold_account_access_cost - @warm_storage_read_cost)

  @doc """
  Access cost of SLOAD: 2,100 cold, 100 warm. Marks the slot warm.
  """
  @spec storage_access_cost(MachineState.t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), MachineState.t()}
  def storage_access_cost(state, address, slot),
    do: slot_cost(state, {address, slot}, @warm_storage_read_cost, @cold_sload_cost)

  @doc """
  Extra access cost of SSTORE: 2,100 when the slot is cold, nothing when
  warm (the SSTORE schedule prices warm writes). Marks the slot warm.
  """
  @spec sstore_access_cost(MachineState.t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), MachineState.t()}
  def sstore_access_cost(state, address, slot),
    do: slot_cost(state, {address, slot}, 0, @cold_sload_cost)

  defp account_cost(state, address, warm_cost, cold_cost) do
    sub = state.substate

    cond do
      not HardforkConfig.enabled?(state.env.config.hardfork, :eip_2929) ->
        {0, state}

      MapSet.member?(sub.accessed_addresses, address) ->
        {warm_cost, state}

      true ->
        new_sub = %{sub | accessed_addresses: MapSet.put(sub.accessed_addresses, address)}
        {cold_cost, %{state | substate: new_sub}}
    end
  end

  defp slot_cost(state, key, warm_cost, cold_cost) do
    sub = state.substate

    cond do
      not HardforkConfig.enabled?(state.env.config.hardfork, :eip_2929) ->
        {0, state}

      MapSet.member?(sub.accessed_storage_keys, key) ->
        {warm_cost, state}

      true ->
        new_sub = %{sub | accessed_storage_keys: MapSet.put(sub.accessed_storage_keys, key)}
        {cold_cost, %{state | substate: new_sub}}
    end
  end

  @spec warm_address?(MachineState.t(), non_neg_integer()) :: boolean()
  def warm_address?(state, address),
    do: MapSet.member?(state.substate.accessed_addresses, address)

  @spec mark_address_warm(MachineState.t(), non_neg_integer()) :: MachineState.t()
  def mark_address_warm(state, address) do
    sub = state.substate
    %{state | substate: %{sub | accessed_addresses: MapSet.put(sub.accessed_addresses, address)}}
  end
end
