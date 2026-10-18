defmodule EEVM.WorldState do
  @moduledoc """
  Minimal world/account state used for external account lookups
  (`EXTCODESIZE`, `EXTCODECOPY`, `EXTCODEHASH`).

  Each account can include `:balance`, `:nonce`, `:code`, and `:storage`.
  Missing accounts behave like non-existent EVM accounts: no code and
  zero balance.
  """

  alias EEVM.Storage

  @type account :: %{
          optional(:balance) => non_neg_integer(),
          optional(:nonce) => non_neg_integer(),
          optional(:code) => binary(),
          optional(:storage) => Storage.t()
        }

  @type t :: %__MODULE__{accounts: %{non_neg_integer() => account()}}

  defstruct accounts: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new(%{optional(non_neg_integer()) => account()}) :: t()
  def new(accounts) when is_map(accounts), do: %__MODULE__{accounts: accounts}

  @spec get_account(t(), non_neg_integer()) :: account() | nil
  def get_account(%__MODULE__{accounts: accounts}, address), do: Map.get(accounts, address)

  @spec account_exists?(t(), non_neg_integer()) :: boolean()
  def account_exists?(%__MODULE__{accounts: accounts}, address),
    do: Map.has_key?(accounts, address)

  @spec get_code(t(), non_neg_integer()) :: binary()
  def get_code(world_state, address) do
    case get_account(world_state, address) do
      nil -> <<>>
      account -> Map.get(account, :code, <<>>)
    end
  end

  @spec get_balance(t(), non_neg_integer()) :: non_neg_integer()
  def get_balance(world_state, address) do
    case get_account(world_state, address) do
      nil -> 0
      account -> Map.get(account, :balance, 0)
    end
  end

  @spec get_nonce(t(), non_neg_integer()) :: non_neg_integer()
  def get_nonce(world_state, address) do
    case get_account(world_state, address) do
      nil -> 0
      account -> Map.get(account, :nonce, 0)
    end
  end

  @spec put_account(t(), non_neg_integer(), account()) :: t()
  def put_account(%__MODULE__{accounts: accounts} = world_state, address, account)
      when is_map(account) do
    %{world_state | accounts: Map.put(accounts, address, account)}
  end

  @doc """
  Removes an account entirely from the world state.

  Used by SELFDESTRUCT under EIP-6780: when a contract is created and
  self-destructed within the same transaction, the account is fully deleted
  (balance, nonce, code, and storage are all removed).
  """
  @spec delete_account(t(), non_neg_integer()) :: t()
  def delete_account(%__MODULE__{accounts: accounts} = world_state, address) do
    %{world_state | accounts: Map.delete(accounts, address)}
  end

  @spec put_code(t(), non_neg_integer(), binary()) :: t()
  def put_code(world_state, address, code) when is_binary(code) do
    update_account(world_state, address, fn account -> Map.put(account, :code, code) end)
  end

  @spec set_balance(t(), non_neg_integer(), non_neg_integer()) :: t()
  def set_balance(world_state, address, balance) do
    update_account(world_state, address, fn account -> Map.put(account, :balance, balance) end)
  end

  @spec set_nonce(t(), non_neg_integer(), non_neg_integer()) :: t()
  def set_nonce(world_state, address, nonce) do
    update_account(world_state, address, fn account -> Map.put(account, :nonce, nonce) end)
  end

  @spec increment_nonce(t(), non_neg_integer()) :: t()
  def increment_nonce(world_state, address) do
    update_account(world_state, address, fn account ->
      Map.put(account, :nonce, Map.get(account, :nonce, 0) + 1)
    end)
  end

  @spec transfer(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, :insufficient_balance}
  def transfer(world_state, _from, _to, 0), do: {:ok, world_state}

  def transfer(world_state, from, to, amount) do
    from_balance = get_balance(world_state, from)

    if from_balance < amount do
      {:error, :insufficient_balance}
    else
      updated_state =
        world_state
        |> set_balance(from, from_balance - amount)
        |> set_balance(to, get_balance(world_state, to) + amount)

      {:ok, updated_state}
    end
  end

  @spec update_account(t(), non_neg_integer(), (account() -> account())) :: t()
  def update_account(world_state, address, updater) when is_function(updater, 1) do
    existing =
      case get_account(world_state, address) do
        nil -> %{}
        account -> account
      end

    put_account(world_state, address, updater.(existing))
  end
end
