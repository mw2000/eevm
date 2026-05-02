defmodule EEVM.Database do
  @moduledoc """
  Behaviour defining the external state interface for the EVM — account
  state (balances, nonces, code) plus per-contract storage — abstracted
  behind a single interface so different backends (in-memory, Merkle-backed,
  disk) can be plugged in without changing opcode implementations.

  A database value is a `%EEVM.Database{}` struct containing:

  - `impl` — the module implementing `@behaviour EEVM.Database`
  - `state` — the implementation-specific state (opaque to callers)

  All public functions in this module dispatch to the `impl` module, passing
  and receiving the opaque `state`. The default implementation is
  `EEVM.Database.InMemory`.
  """

  @type account :: %{
          optional(:balance) => non_neg_integer(),
          optional(:nonce) => non_neg_integer(),
          optional(:code) => binary(),
          optional(:storage) => EEVM.Storage.t()
        }

  @type t :: %__MODULE__{
          impl: module(),
          state: term()
        }

  defstruct [:impl, :state]

  # ---------------------------------------------------------------------------
  # Account read callbacks
  # ---------------------------------------------------------------------------

  @doc "Fetch the full account record, or nil if the address has no state."
  @callback get_account(state :: term(), address :: non_neg_integer()) :: account() | nil

  @doc "Check whether an account exists at the given address."
  @callback account_exists?(state :: term(), address :: non_neg_integer()) :: boolean()

  @doc "Return the bytecode deployed at `address` (empty binary if none)."
  @callback get_code(state :: term(), address :: non_neg_integer()) :: binary()

  @doc "Return the balance in wei for `address` (0 if non-existent)."
  @callback get_balance(state :: term(), address :: non_neg_integer()) :: non_neg_integer()

  @doc "Return the nonce for `address` (0 if non-existent)."
  @callback get_nonce(state :: term(), address :: non_neg_integer()) :: non_neg_integer()

  @doc "Return whether account at `address` is EIP-161 empty."
  @callback account_empty?(state :: term(), address :: non_neg_integer()) :: boolean()

  # ---------------------------------------------------------------------------
  # Account write callbacks
  # ---------------------------------------------------------------------------

  @doc "Replace the entire account record at `address`."
  @callback put_account(state :: term(), address :: non_neg_integer(), account :: account()) ::
              term()

  @doc "Remove an account entirely (used by SELFDESTRUCT under EIP-6780)."
  @callback delete_account(state :: term(), address :: non_neg_integer()) :: term()

  @doc "Set the bytecode at `address`."
  @callback put_code(state :: term(), address :: non_neg_integer(), code :: binary()) :: term()

  @doc "Set the balance at `address`."
  @callback set_balance(
              state :: term(),
              address :: non_neg_integer(),
              balance :: non_neg_integer()
            ) :: term()

  @doc "Set the nonce at `address`."
  @callback set_nonce(state :: term(), address :: non_neg_integer(), nonce :: non_neg_integer()) ::
              term()

  @doc "Increment the nonce at `address` by 1."
  @callback increment_nonce(state :: term(), address :: non_neg_integer()) :: term()

  @doc "Transfer `amount` wei from one address to another."
  @callback transfer(
              state :: term(),
              from :: non_neg_integer(),
              to :: non_neg_integer(),
              amount :: non_neg_integer()
            ) :: {:ok, term()} | {:error, :insufficient_balance}

  # ---------------------------------------------------------------------------
  # Storage callbacks
  # ---------------------------------------------------------------------------

  @doc "Load a 256-bit storage slot for the given contract address."
  @callback storage_load(
              state :: term(),
              address :: non_neg_integer(),
              key :: non_neg_integer()
            ) :: non_neg_integer()

  @doc "Return all known account addresses in the backend state."
  @callback account_addresses(state :: term()) :: [non_neg_integer()]

  @doc "Return all storage slots currently tracked for an address."
  @callback storage_slots(state :: term(), address :: non_neg_integer()) ::
              [{non_neg_integer(), non_neg_integer()}]

  @doc "Return addresses that currently have tracked storage entries."
  @callback storage_addresses(state :: term()) :: [non_neg_integer()]

  @doc "Store a 256-bit value into a storage slot for the given contract address."
  @callback storage_store(
              state :: term(),
              address :: non_neg_integer(),
              key :: non_neg_integer(),
              value :: non_neg_integer()
            ) :: term()

  # ---------------------------------------------------------------------------
  # Constructor
  # ---------------------------------------------------------------------------

  @doc """
  Wraps an implementation module and its initial state into a `%Database{}`.

  ## Example

      db = Database.new(Database.InMemory, Database.InMemory.init())
  """
  @spec new(module(), term()) :: t()
  def new(impl, state) do
    %__MODULE__{impl: impl, state: state}
  end

  # ---------------------------------------------------------------------------
  # Public API — dispatches to the implementation module
  # ---------------------------------------------------------------------------

  @spec get_account(t(), non_neg_integer()) :: account() | nil
  def get_account(%__MODULE__{impl: impl, state: state}, address) do
    impl.get_account(state, address)
  end

  @spec account_exists?(t(), non_neg_integer()) :: boolean()
  def account_exists?(%__MODULE__{impl: impl, state: state}, address) do
    impl.account_exists?(state, address)
  end

  @spec get_code(t(), non_neg_integer()) :: binary()
  def get_code(%__MODULE__{impl: impl, state: state}, address) do
    impl.get_code(state, address)
  end

  @spec get_balance(t(), non_neg_integer()) :: non_neg_integer()
  def get_balance(%__MODULE__{impl: impl, state: state}, address) do
    impl.get_balance(state, address)
  end

  @spec get_nonce(t(), non_neg_integer()) :: non_neg_integer()
  def get_nonce(%__MODULE__{impl: impl, state: state}, address) do
    impl.get_nonce(state, address)
  end

  @spec account_empty?(t(), non_neg_integer()) :: boolean()
  def account_empty?(%__MODULE__{impl: impl, state: state}, address) do
    impl.account_empty?(state, address)
  end

  @spec put_account(t(), non_neg_integer(), account()) :: t()
  def put_account(%__MODULE__{impl: impl, state: state} = db, address, account) do
    %{db | state: impl.put_account(state, address, account)}
  end

  @spec delete_account(t(), non_neg_integer()) :: t()
  def delete_account(%__MODULE__{impl: impl, state: state} = db, address) do
    %{db | state: impl.delete_account(state, address)}
  end

  @spec put_code(t(), non_neg_integer(), binary()) :: t()
  def put_code(%__MODULE__{impl: impl, state: state} = db, address, code) do
    %{db | state: impl.put_code(state, address, code)}
  end

  @spec set_balance(t(), non_neg_integer(), non_neg_integer()) :: t()
  def set_balance(%__MODULE__{impl: impl, state: state} = db, address, balance) do
    %{db | state: impl.set_balance(state, address, balance)}
  end

  @spec set_nonce(t(), non_neg_integer(), non_neg_integer()) :: t()
  def set_nonce(%__MODULE__{impl: impl, state: state} = db, address, nonce) do
    %{db | state: impl.set_nonce(state, address, nonce)}
  end

  @spec increment_nonce(t(), non_neg_integer()) :: t()
  def increment_nonce(%__MODULE__{impl: impl, state: state} = db, address) do
    %{db | state: impl.increment_nonce(state, address)}
  end

  @spec transfer(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, :insufficient_balance}
  def transfer(%__MODULE__{impl: impl, state: state} = db, from, to, amount) do
    case impl.transfer(state, from, to, amount) do
      {:ok, new_state} -> {:ok, %{db | state: new_state}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec storage_load(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def storage_load(%__MODULE__{impl: impl, state: state}, address, key) do
    impl.storage_load(state, address, key)
  end

  @spec account_addresses(t()) :: [non_neg_integer()]
  def account_addresses(%__MODULE__{impl: impl, state: state}) do
    impl.account_addresses(state)
  end

  @spec storage_slots(t(), non_neg_integer()) :: [{non_neg_integer(), non_neg_integer()}]
  def storage_slots(%__MODULE__{impl: impl, state: state}, address) do
    impl.storage_slots(state, address)
  end

  @spec storage_addresses(t()) :: [non_neg_integer()]
  def storage_addresses(%__MODULE__{impl: impl, state: state}) do
    impl.storage_addresses(state)
  end

  @spec storage_store(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def storage_store(%__MODULE__{impl: impl, state: state} = db, address, key, value) do
    %{db | state: impl.storage_store(state, address, key, value)}
  end
end
