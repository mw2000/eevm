defmodule EEVM.StateRoot do
  @moduledoc """
  Computes Ethereum storage roots and state roots from the current `EEVM.Database`.

  The first state root of a database enumerates the backend through
  `c:EEVM.Database.accounts/1` and `c:EEVM.Database.storage_slots/2`, so the
  backend must support them. `update/1` keeps the hashed tries in the
  database it returns, and every database derived from that one by writes
  and `EEVM.Database.commit/1` carries them along with the addresses and
  slots written since. The next state root rehashes only those paths, so a
  block costs Keccak work in proportion to what it wrote, not to the size of
  the state (#203). `EEVM.Block.execute/4` and `EEVM.Block.build/4` use it,
  so the databases in their results, committed or not, carry the tries to
  the next block.
  """

  alias EEVM.Crypto.Keccak
  alias EEVM.{Database, StateChanges}
  alias EEVM.MPT.Trie

  @empty_code_hash <<0xC5D2460186F7233C927E7DB2DCC703C0E500B653CA82273B7BFAD8045D85A470::256>>

  @typedoc """
  Hashed tries for some earlier state, and what changed since: for each
  address, the slots written, or `:all` when its storage was cleared. Kept
  in `EEVM.Database`'s `:tries` field.
  """
  @opaque tries :: %{
            accounts: Trie.t(),
            storage: %{Database.address() => Trie.t()},
            stale: %{Database.address() => :all | MapSet.t(non_neg_integer())}
          }

  @doc "Returns the storage trie root of `address`."
  @spec compute_storage_root(Database.t(), non_neg_integer()) :: binary()
  def compute_storage_root(%Database{} = db, address) when is_integer(address) and address >= 0 do
    db |> storage_trie(address, :all, Trie.new()) |> Trie.hash() |> elem(0)
  end

  @doc "Returns the world-state trie root of `db`, overlay included."
  @spec compute_state_root(Database.t()) :: binary()
  def compute_state_root(%Database{} = db), do: db |> update() |> elem(0)

  @doc """
  Returns the world-state trie root of `db`, overlay included, and `db`
  with its hashed tries updated, so the next state root of it, or of a
  database written or committed from it, rehashes only what changed.

  ## Example

      iex> alias EEVM.Database
      iex> {_root, db} = EEVM.StateRoot.update(Database.InMemory.new(accounts: %{1 => %{balance: 5}}))
      iex> {:ok, db} = db |> Database.set_balance(2, 7) |> Database.commit()
      iex> {root, _db} = EEVM.StateRoot.update(db)
      iex> fresh = Database.InMemory.new(accounts: %{1 => %{balance: 5}, 2 => %{balance: 7}})
      iex> root == EEVM.StateRoot.compute_state_root(fresh)
      true
  """
  @spec update(Database.t()) :: {binary(), Database.t()}
  def update(%Database{tries: nil} = db) do
    stale = Map.new(Database.account_addresses(db), &{&1, :all})
    update(%{db | tries: %{accounts: Trie.new(), storage: %{}, stale: stale}})
  end

  def update(%Database{tries: tries} = db) do
    stale = mark_stale(tries, Database.changes(db)).stale
    {accounts, storage} = Enum.reduce(stale, {tries.accounts, tries.storage}, &rehash(db, &1, &2))
    {root, accounts} = Trie.hash(accounts)
    {root, %{db | tries: %{accounts: accounts, storage: storage, stale: %{}}}}
  end

  # Brings one stale address's storage trie and account leaf up to date.
  defp rehash(db, {address, slots}, {accounts, storage}) do
    {storage_root, storage_trie} =
      db |> storage_trie(address, slots, Map.get(storage, address, Trie.new())) |> Trie.hash()

    key = Keccak.hash_256(<<address::160>>)

    storage =
      if Trie.empty?(storage_trie),
        do: Map.delete(storage, address),
        else: Map.put(storage, address, storage_trie)

    if Trie.empty?(storage_trie) and not Database.account_exists?(db, address),
      do: {Trie.delete(accounts, key), storage},
      else: {Trie.put(accounts, key, encode_account(db, address, storage_root)), storage}
  end

  @doc false
  # Records `changes` as written since `tries` were hashed; `EEVM.Database`
  # calls it when it commits, because the overlay that listed them is gone.
  @spec mark_stale(tries() | nil, StateChanges.t()) :: tries() | nil
  def mark_stale(nil, _changes), do: nil

  def mark_stale(tries, %StateChanges{accounts: changes}) do
    stale =
      Enum.reduce(changes, tries.stale, fn {address, change}, stale ->
        case change do
          %{destroyed?: false, storage: written} ->
            Map.update(stale, address, MapSet.new(Map.keys(written)), fn
              :all -> :all
              slots -> Enum.into(Map.keys(written), slots)
            end)

          # Destroyed: every slot it had is gone.
          _destroyed ->
            Map.put(stale, address, :all)
        end
      end)

    %{tries | stale: stale}
  end

  # A cleared store is rebuilt from what the database enumerates; otherwise
  # only the written slots are read.
  defp storage_trie(db, address, :all, _trie) do
    db
    |> Database.storage_slots(address)
    |> Enum.reduce(Trie.new(), fn {slot, value}, trie -> put_slot(trie, slot, value) end)
  end

  defp storage_trie(db, address, slots, trie) do
    Enum.reduce(slots, trie, fn slot, trie ->
      put_slot(trie, slot, Database.storage_load(db, address, slot))
    end)
  end

  defp put_slot(trie, slot, 0), do: Trie.delete(trie, Keccak.hash_256(<<slot::256>>))

  defp put_slot(trie, slot, value),
    do: Trie.put(trie, Keccak.hash_256(<<slot::256>>), ExRLP.encode(value))

  defp encode_account(db, address, storage_root) do
    nonce = Database.get_nonce(db, address)
    balance = Database.get_balance(db, address)
    code_hash = Database.get_code_hash(db, address) || @empty_code_hash

    ExRLP.encode([nonce, balance, storage_root, code_hash])
  end
end
