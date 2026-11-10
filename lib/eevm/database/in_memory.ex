defmodule EEVM.Database.InMemory do
  @moduledoc """
  In-memory `EEVM.Database` backend backed by plain maps. It implements
  every callback, `commit/2` included, so `EEVM.transact/4` and
  `EEVM.Block.execute/4` return it with their changes applied.

  The state is a map with these keys:

  - `:accounts` — `%{address => %{balance, nonce, code, code_hash}}`
  - `:storage` — `%{address => %{slot => value}}` (per-contract storage)
  - `:codes` — `%{code_hash => code}`
  - `:block_hashes` — `%{number => hash}`, served to BLOCKHASH

  The pre-1.0 write and query functions (`get_balance/2`, `set_balance/3`,
  and so on) still work on this state but are deprecated; use the
  `EEVM.Database` functions on a database from `new/1`.
  """

  @behaviour EEVM.Database

  alias EEVM.Crypto.Keccak
  alias EEVM.{Database, StateChanges}

  @empty_code_hash <<0xC5D2460186F7233C927E7DB2DCC703C0E500B653CA82273B7BFAD8045D85A470::256>>

  @type state :: %{
          accounts: %{non_neg_integer() => map()},
          storage: %{non_neg_integer() => %{non_neg_integer() => non_neg_integer()}},
          codes: %{binary() => binary()},
          block_hashes: %{non_neg_integer() => <<_::256>>}
        }

  @doc """
  Creates a new in-memory database state.

  ## Options

  - `:accounts` — `%{address => %{balance:, nonce:, code:}}`; missing fields
    default to zero and no code (default `%{}`)
  - `:storage` — `%{address => %{slot => value}}` (default `%{}`)
  - `:block_hashes` — `%{number => <<_::256>>}` for BLOCKHASH (default `%{}`)

  ## Example

      iex> state = EEVM.Database.InMemory.init(accounts: %{1 => %{balance: 100}})
      iex> EEVM.Database.InMemory.account(state, 1)
      {:ok, %{balance: 100, nonce: 0, code: <<>>, code_hash: EEVM.Database.InMemory.empty_code_hash()}}
  """
  @spec init(keyword()) :: state()
  def init(opts \\ []) do
    accounts =
      Map.new(Keyword.get(opts, :accounts, %{}), fn {address, account} ->
        {address, normalize(account)}
      end)

    %{
      accounts: accounts,
      storage: Keyword.get(opts, :storage, %{}),
      codes: Map.new(accounts, fn {_address, account} -> {account.code_hash, account.code} end),
      block_hashes: Keyword.get(opts, :block_hashes, %{})
    }
  end

  @doc """
  Creates a database with this backend; takes the options of `init/1`.

  ## Example

      iex> db = EEVM.Database.InMemory.new(accounts: %{1 => %{balance: 100}})
      iex> EEVM.Database.get_balance(db, 1)
      100
  """
  @spec new(keyword()) :: Database.t()
  def new(opts \\ []), do: Database.new(__MODULE__, init(opts))

  @doc "Returns keccak256 of empty code, the code hash of an account with no code."
  @spec empty_code_hash() :: <<_::256>>
  def empty_code_hash, do: @empty_code_hash

  # ---------------------------------------------------------------------------
  # EEVM.Database callbacks
  # ---------------------------------------------------------------------------

  @impl Database
  def account(%{accounts: accounts}, address), do: {:ok, Map.get(accounts, address)}

  @impl Database
  def code(%{codes: codes}, code_hash), do: {:ok, Map.get(codes, code_hash, <<>>)}

  @impl Database
  def storage(%{storage: storage}, address, slot),
    do: {:ok, storage |> Map.get(address, %{}) |> Map.get(slot, 0)}

  @impl Database
  def block_hash(%{block_hashes: hashes}, number), do: {:ok, Map.get(hashes, number)}

  @impl Database
  def commit(state, %StateChanges{accounts: changes}),
    do: {:ok, Enum.reduce(changes, state, &apply_change/2)}

  @impl Database
  def accounts(%{accounts: accounts, storage: storage}),
    do: {:ok, Enum.uniq(Map.keys(accounts) ++ Map.keys(storage))}

  @impl Database
  def storage_slots(%{storage: storage}, address),
    do: {:ok, Map.to_list(Map.get(storage, address, %{}))}

  defp apply_change({address, :destroyed}, state) do
    %{
      state
      | accounts: Map.delete(state.accounts, address),
        storage: Map.delete(state.storage, address)
    }
  end

  defp apply_change({address, change}, state) do
    old_slots = if change.destroyed?, do: %{}, else: Map.get(state.storage, address, %{})

    slots =
      Enum.reduce(change.storage, old_slots, fn
        {slot, 0}, acc -> Map.delete(acc, slot)
        {slot, value}, acc -> Map.put(acc, slot, value)
      end)

    code = change.code || Map.get(state.codes, change.code_hash, <<>>)

    %{
      state
      | accounts:
          Map.put(state.accounts, address, %{
            balance: change.balance,
            nonce: change.nonce,
            code: code,
            code_hash: change.code_hash
          }),
        storage:
          if(slots == %{},
            do: Map.delete(state.storage, address),
            else: Map.put(state.storage, address, slots)
          ),
        codes: Map.put(state.codes, change.code_hash, code)
    }
  end

  defp normalize(account) do
    code = Map.get(account, :code, <<>>)

    %{
      balance: Map.get(account, :balance, 0),
      nonce: Map.get(account, :nonce, 0),
      code: code,
      code_hash: if(code == <<>>, do: @empty_code_hash, else: Keccak.hash_256(code))
    }
  end

  # ---------------------------------------------------------------------------
  # Deprecated pre-1.0 functions on the raw state
  # ---------------------------------------------------------------------------

  @doc false
  @deprecated "Use EEVM.Database.get_account/2"
  def get_account(state, address), do: state |> wrap() |> Database.get_account(address)

  @doc false
  @deprecated "Use EEVM.Database.account_exists?/2"
  def account_exists?(state, address), do: Map.has_key?(state.accounts, address)

  @doc false
  @deprecated "Use EEVM.Database.get_code/2"
  def get_code(state, address), do: state |> wrap() |> Database.get_code(address)

  @doc false
  @deprecated "Use EEVM.Database.get_balance/2"
  def get_balance(state, address), do: state |> wrap() |> Database.get_balance(address)

  @doc false
  @deprecated "Use EEVM.Database.get_nonce/2"
  def get_nonce(state, address), do: state |> wrap() |> Database.get_nonce(address)

  @doc false
  @deprecated "Use EEVM.Database.account_empty?/2"
  def account_empty?(state, address), do: state |> wrap() |> Database.account_empty?(address)

  @doc false
  @deprecated "Use EEVM.Database.storage_load/3"
  def storage_load(state, address, key),
    do: state |> wrap() |> Database.storage_load(address, key)

  @doc false
  @deprecated "Use EEVM.Database.account_addresses/1"
  def account_addresses(state), do: state |> accounts() |> elem(1)

  @doc false
  @deprecated "Use EEVM.Database.account_addresses/1"
  def storage_addresses(%{storage: storage}), do: Map.keys(storage)

  @doc false
  @deprecated "Use EEVM.Database.put_account/3"
  def put_account(state, address, account),
    do: write(state, &Database.put_account(&1, address, account))

  @doc false
  @deprecated "Use EEVM.Database.delete_account/2"
  def delete_account(state, address), do: write(state, &Database.delete_account(&1, address))

  @doc false
  @deprecated "Use EEVM.Database.put_code/3"
  def put_code(state, address, code), do: write(state, &Database.put_code(&1, address, code))

  @doc false
  @deprecated "Use EEVM.Database.set_balance/3"
  def set_balance(state, address, balance),
    do: write(state, &Database.set_balance(&1, address, balance))

  @doc false
  @deprecated "Use EEVM.Database.set_nonce/3"
  def set_nonce(state, address, nonce), do: write(state, &Database.set_nonce(&1, address, nonce))

  @doc false
  @deprecated "Use EEVM.Database.increment_nonce/2"
  def increment_nonce(state, address), do: write(state, &Database.increment_nonce(&1, address))

  @doc false
  @deprecated "Use EEVM.Database.storage_store/4"
  def storage_store(state, address, key, value),
    do: write(state, &Database.storage_store(&1, address, key, value))

  @doc false
  @deprecated "Use EEVM.Database.transfer/4"
  def transfer(state, from, to, amount) do
    with {:ok, db} <- Database.transfer(wrap(state), from, to, amount) do
      {:ok, committed_state(db)}
    end
  end

  defp wrap(state), do: %Database{impl: __MODULE__, state: state}

  defp write(state, fun), do: state |> wrap() |> fun.() |> committed_state()

  defp committed_state(db) do
    {:ok, %Database{state: state}} = Database.commit(db)
    state
  end
end
