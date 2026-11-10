defmodule EEVM.Database.Legacy do
  @moduledoc deprecated: "Implement the EEVM.Database read callbacks instead"
  @moduledoc """
  Adapts a backend written against the pre-1.0 `EEVM.Database` callbacks
  (`get_account/2`, `get_balance/2`, `set_balance/3`, `storage_store/4`, ...)
  to the read-only behaviour. `EEVM.Database.new/2` wraps such a module
  automatically; this shim is kept for one minor version.

  Its state is `{module, module_state}`. Reads call the old query callbacks,
  `commit/2` replays the changes through the old write callbacks, and
  BLOCKHASH falls back to the block environment only.
  """

  @behaviour EEVM.Database

  alias EEVM.StateChanges

  @impl true
  def account({impl, state}, address) do
    if impl.account_exists?(state, address) do
      {:ok,
       %{
         balance: impl.get_balance(state, address),
         nonce: impl.get_nonce(state, address),
         code: impl.get_code(state, address)
       }}
    else
      {:ok, nil}
    end
  end

  # Code always comes with the account, so this is never asked for.
  @impl true
  def code(_state, _code_hash), do: {:error, :code_by_hash_unsupported}

  @impl true
  def storage({impl, state}, address, slot), do: {:ok, impl.storage_load(state, address, slot)}

  @impl true
  def block_hash(_state, _number), do: {:ok, nil}

  @impl true
  def commit({impl, state}, %StateChanges{accounts: changes}) do
    {:ok, {impl, Enum.reduce(changes, state, &apply_change(impl, &1, &2))}}
  end

  @impl true
  def accounts({impl, state}),
    do: Enum.uniq(impl.account_addresses(state) ++ impl.storage_addresses(state))

  @impl true
  def storage_slots({impl, state}, address), do: impl.storage_slots(state, address)

  defp apply_change(impl, {address, :destroyed}, state), do: impl.delete_account(state, address)

  defp apply_change(impl, {address, change}, state) do
    state = if change.destroyed?, do: impl.delete_account(state, address), else: state

    state =
      impl.put_account(state, address, %{
        balance: change.balance,
        nonce: change.nonce,
        code: change.code || impl.get_code(state, address)
      })

    Enum.reduce(change.storage, state, fn {slot, value}, acc ->
      impl.storage_store(acc, address, slot, value)
    end)
  end
end
