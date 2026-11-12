defmodule Devx.ReadOnlyDatabase do
  @moduledoc """
  Task 5, read-only: the ETS table of `Devx.EtsDatabase` behind an adapter
  that implements only the four reads. `use EEVM.Database` supplies
  `commit/2`, `accounts/1`, and `storage_slots/2` as `{:error, :unsupported}`,
  so eevm never writes to the table and results keep their writes.
  """
  use EEVM.Database

  @doc "Wraps `table` read-only."
  def new(table), do: EEVM.Database.new(__MODULE__, table)

  @impl true
  defdelegate account(table, address), to: Devx.EtsDatabase

  @impl true
  defdelegate code(table, code_hash), to: Devx.EtsDatabase

  @impl true
  defdelegate storage(table, address, slot), to: Devx.EtsDatabase

  @impl true
  defdelegate block_hash(table, number), to: Devx.EtsDatabase
end
