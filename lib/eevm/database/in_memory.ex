defmodule EEVM.Database.InMemory do
  @moduledoc """
  In-memory database implementation using plain maps.

  ## EVM Concepts

  This is the default database backend for eevm. It stores all account state
  (balances, nonces, code) and contract storage in Elixir maps — the same
  data structures used by `EEVM.WorldState` and `EEVM.Storage` before the
  Database abstraction was introduced.

  The state is a map with two keys:

  - `:accounts` — `%{address => account_map}` (balances, nonces, code)
  - `:storage` — `%{address => %{slot => value}}` (per-contract storage)

  This implementation is suitable for testing, single-transaction execution,
  and learning. For production use with persistent state, implement the
  `EEVM.Database` behaviour with a disk-backed store.

  ## Elixir Learning Notes

  - `@behaviour EEVM.Database` tells the compiler to verify that this module
    implements all required callbacks. Missing callbacks produce warnings.
  - The state is a plain map (not a struct) to keep it lightweight and
    easy to inspect in tests.
  """

  @behaviour EEVM.Database

  alias EEVM.Database

  @type state :: %{
          accounts: %{non_neg_integer() => Database.account()},
          storage: %{non_neg_integer() => %{non_neg_integer() => non_neg_integer()}}
        }

  @doc """
  Creates a new in-memory database state.

  ## Options

  - `:accounts` — initial account map (default: `%{}`)
  - `:storage` — initial per-address storage map (default: `%{}`)

  ## Examples

      iex> state = EEVM.Database.InMemory.init()
      iex> EEVM.Database.InMemory.get_balance(state, 0x1234)
      0

      iex> state = EEVM.Database.InMemory.init(accounts: %{1 => %{balance: 100}})
      iex> EEVM.Database.InMemory.get_balance(state, 1)
      100
  """
  @spec init(keyword()) :: state()
  def init(opts \\ []) do
    %{
      accounts: Keyword.get(opts, :accounts, %{}),
      storage: Keyword.get(opts, :storage, %{})
    }
  end

  @doc """
  Convenience: creates a fully wrapped `%Database{}` with InMemory backend.

  This is the most common way to create a database for execution.

  ## Examples

      iex> db = EEVM.Database.InMemory.new()
      iex> EEVM.Database.get_balance(db, 0x1234)
      0
  """
  @spec new(keyword()) :: Database.t()
  def new(opts \\ []) do
    Database.new(__MODULE__, init(opts))
  end

  # ---------------------------------------------------------------------------
  # Account reads
  # ---------------------------------------------------------------------------

  @impl true
  def get_account(%{accounts: accounts}, address) do
    Map.get(accounts, address)
  end

  @impl true
  def account_exists?(%{accounts: accounts}, address) do
    Map.has_key?(accounts, address)
  end

  @impl true
  def get_code(state, address) do
    case get_account(state, address) do
      nil -> <<>>
      account -> Map.get(account, :code, <<>>)
    end
  end

  @impl true
  def get_balance(state, address) do
    case get_account(state, address) do
      nil -> 0
      account -> Map.get(account, :balance, 0)
    end
  end

  @impl true
  def get_nonce(state, address) do
    case get_account(state, address) do
      nil -> 0
      account -> Map.get(account, :nonce, 0)
    end
  end

  # ---------------------------------------------------------------------------
  # Account writes
  # ---------------------------------------------------------------------------

  @impl true
  def put_account(%{accounts: accounts} = state, address, account) when is_map(account) do
    %{state | accounts: Map.put(accounts, address, account)}
  end

  @impl true
  def delete_account(%{accounts: accounts} = state, address) do
    %{state | accounts: Map.delete(accounts, address)}
  end

  @impl true
  def put_code(state, address, code) when is_binary(code) do
    update_account(state, address, fn account -> Map.put(account, :code, code) end)
  end

  @impl true
  def set_balance(state, address, balance) do
    update_account(state, address, fn account -> Map.put(account, :balance, balance) end)
  end

  @impl true
  def set_nonce(state, address, nonce) do
    update_account(state, address, fn account -> Map.put(account, :nonce, nonce) end)
  end

  @impl true
  def increment_nonce(state, address) do
    update_account(state, address, fn account ->
      Map.put(account, :nonce, Map.get(account, :nonce, 0) + 1)
    end)
  end

  @impl true
  def transfer(state, _from, _to, 0), do: {:ok, state}

  def transfer(state, from, to, amount) do
    from_balance = get_balance(state, from)

    if from_balance < amount do
      {:error, :insufficient_balance}
    else
      updated_state =
        state
        |> set_balance(from, from_balance - amount)
        |> set_balance(to, get_balance(state, to) + amount)

      {:ok, updated_state}
    end
  end

  # ---------------------------------------------------------------------------
  # Storage
  # ---------------------------------------------------------------------------

  @impl true
  def storage_load(%{storage: storage}, address, key) do
    storage
    |> Map.get(address, %{})
    |> Map.get(key, 0)
  end

  @impl true
  def account_addresses(%{accounts: accounts}) do
    Map.keys(accounts)
  end

  @impl true
  def storage_slots(%{storage: storage}, address) do
    storage
    |> Map.get(address, %{})
    |> Map.to_list()
  end

  @impl true
  def storage_addresses(%{storage: storage}) do
    Map.keys(storage)
  end

  @impl true
  def storage_store(%{storage: storage} = state, address, key, value) do
    address_storage = Map.get(storage, address, %{})
    updated_slot = Map.put(address_storage, key, band_256(value))
    %{state | storage: Map.put(storage, address, updated_slot)}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp update_account(state, address, updater) when is_function(updater, 1) do
    existing =
      case get_account(state, address) do
        nil -> %{}
        account -> account
      end

    put_account(state, address, updater.(existing))
  end

  defp band_256(value) do
    import Bitwise
    Bitwise.band(value, (1 <<< 256) - 1)
  end
end
