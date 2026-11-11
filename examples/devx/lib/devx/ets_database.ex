defmodule Devx.EtsDatabase do
  @moduledoc """
  Task 5: a custom `EEVM.Database` backend over an ETS table, following the
  \"Writing a database adapter\" guide. The table outlives each call and can be
  shared between processes; `commit/2` writes to it.
  """
  @behaviour EEVM.Database

  # Keys: {:account, address}, {:code, hash}, {:storage, address, slot}, and {:block_hash, number}.

  @doc "Wraps `table` (a new one by default) as an eevm database."
  def new(table \\ :ets.new(:devx_state, [:set, :public])),
    do: EEVM.Database.new(__MODULE__, table)

  @doc "Adds an account to the table."
  def seed(table, address, account), do: :ets.insert(table, {{:account, address}, account})

  @impl true
  def account(table, address), do: {:ok, get(table, {:account, address})}

  @impl true
  def code(table, code_hash), do: {:ok, get(table, {:code, code_hash}) || <<>>}

  @impl true
  def storage(table, address, slot), do: {:ok, get(table, {:storage, address, slot}) || 0}

  @impl true
  def block_hash(table, number), do: {:ok, get(table, {:block_hash, number})}

  @impl true
  def commit(table, %EEVM.StateChanges{accounts: changes}) do
    Enum.each(changes, fn
      {address, :destroyed} ->
        delete_account(table, address)

      {address, change} ->
        if change.destroyed?, do: delete_account(table, address)

        :ets.insert(
          table,
          {{:account, address}, Map.take(change, [:balance, :nonce, :code_hash])}
        )

        if change.code, do: :ets.insert(table, {{:code, change.code_hash}, change.code})

        Enum.each(change.storage, fn
          {slot, 0} -> :ets.delete(table, {:storage, address, slot})
          {slot, value} -> :ets.insert(table, {{:storage, address, slot}, value})
        end)
    end)

    {:ok, table}
  end

  @impl true
  def accounts(table), do: {:ok, :ets.select(table, [{{{:account, :"$1"}, :_}, [], [:"$1"]}])}

  @impl true
  def storage_slots(table, address),
    do: {:ok, :ets.select(table, [{{{:storage, address, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])}

  defp delete_account(table, address) do
    :ets.delete(table, {:account, address})
    :ets.match_delete(table, {{:storage, address, :_}, :_})
  end

  defp get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end
end
