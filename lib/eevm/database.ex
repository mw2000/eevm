defmodule EEVM.Database do
  @moduledoc """
  World state: a read-only backend plus eevm's own write overlay.

  A backend implements this behaviour's read callbacks, `c:account/2`,
  `c:code/2`, `c:storage/3`, and `c:block_hash/2`. eevm never writes to it
  during execution: every balance, nonce, code, and storage write lands in
  the overlay this struct carries. Because a `%EEVM.Database{}` is an
  immutable value, reverting a call frame is just dropping its copy.

  When a transaction or block finishes, `changes/1` returns the overlay as an
  `EEVM.StateChanges`. `EEVM.transact/4` and `EEVM.Block.execute/4` hand it
  to the backend's optional `c:commit/2` and return the committed database;
  with a backend that has no `commit/2`, the result keeps the overlay and
  the caller applies `result.changes` itself. `EEVM.run/2` never commits.

  `EEVM.StateRoot` also needs to enumerate the backend, through the optional
  `c:accounts/1` and `c:storage_slots/2`; an RPC-backed adapter can leave
  them out and still execute transactions. Without `c:storage_slots/2`, the
  EIP-7610 check that a CREATE target has no storage sees only the overlay.

  `EEVM.Database.InMemory` implements every callback. See the "Writing a
  database adapter" guide to write your own.

  ## Read errors

  A callback that returns `{:error, reason}` aborts execution: the entry
  point (`EEVM.run/2`, `EEVM.transact/4`, `EEVM.Block.execute/4`, or
  `EEVM.Block.build/4`) returns `{:error, {:database, reason}}`. Called
  directly, the functions in this module raise `EEVM.Database.ReadError`.

  ## Deprecated callbacks

  Before 1.0 the behaviour also had write and query callbacks
  (`get_account/2`, `set_balance/3`, `storage_store/4`, and so on). A module
  that implements only those still works for one minor version: `new/2`
  wraps it in `EEVM.Database.Legacy`.
  """

  alias EEVM.StateChanges

  defmodule ReadError do
    @moduledoc "Raised when a database backend returns `{:error, reason}` from a read."
    defexception [:reason]

    @impl true
    def message(%{reason: reason}), do: "database read failed: #{inspect(reason)}"
  end

  @empty_code_hash <<0xC5D2460186F7233C927E7DB2DCC703C0E500B653CA82273B7BFAD8045D85A470::256>>

  @typedoc "An address: a 160-bit integer."
  @type address :: non_neg_integer()

  @typedoc """
  An account as a backend returns it. `code` may be included to save a
  `c:code/2` call; when it is, `code_hash` may be left out.
  """
  @type backend_account :: %{
          required(:balance) => non_neg_integer(),
          required(:nonce) => non_neg_integer(),
          optional(:code_hash) => <<_::256>>,
          optional(:code) => binary()
        }

  @typedoc "An account record: balance, nonce, and code."
  @type account :: %{
          optional(:balance) => non_neg_integer(),
          optional(:nonce) => non_neg_integer(),
          optional(:code) => binary()
        }

  # An overlay account. `code` is nil until loaded from the backend.
  @typep overlay_account :: %{
           balance: non_neg_integer(),
           nonce: non_neg_integer(),
           code_hash: <<_::256>>,
           code: binary() | nil
         }

  @type t :: %__MODULE__{
          impl: module(),
          state: term(),
          accounts: %{address() => overlay_account() | nil},
          storage: %{address() => %{non_neg_integer() => non_neg_integer()}},
          destroyed: MapSet.t(address())
        }

  defstruct [:impl, :state, accounts: %{}, storage: %{}, destroyed: MapSet.new()]

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @doc "Returns the account at `address`, or `nil` when it doesn't exist."
  @callback account(state :: term(), address()) ::
              {:ok, backend_account() | nil} | {:error, term()}

  @doc "Returns the code whose keccak256 hash is `code_hash`."
  @callback code(state :: term(), code_hash :: <<_::256>>) :: {:ok, binary()} | {:error, term()}

  @doc "Returns the storage word at `slot` of `address` (0 when unset)."
  @callback storage(state :: term(), address(), slot :: non_neg_integer()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Returns the hash of block `number`, or `nil` when unknown. BLOCKHASH asks
  only for blocks the `EEVM.BlockEnv` doesn't already carry.
  """
  @callback block_hash(state :: term(), number :: non_neg_integer()) ::
              {:ok, <<_::256>> | nil} | {:error, term()}

  @doc "Applies a finished set of changes and returns the new backend state."
  @callback commit(state :: term(), StateChanges.t()) :: {:ok, term()} | {:error, term()}

  @doc "Enumerates every address with an account or storage. Needed only for state roots."
  @callback accounts(state :: term()) :: Enumerable.t()

  @doc "Enumerates `{slot, value}` for every set slot of `address`. Needed only for state roots."
  @callback storage_slots(state :: term(), address()) :: Enumerable.t()

  @optional_callbacks commit: 2, accounts: 1, storage_slots: 2

  # ---------------------------------------------------------------------------
  # Constructor and commit
  # ---------------------------------------------------------------------------

  @doc """
  Wraps a backend module and its state, with an empty overlay.

  A module that implements only the deprecated pre-1.0 callbacks is wrapped
  in `EEVM.Database.Legacy`.

  ## Example

      iex> db = EEVM.Database.new(EEVM.Database.InMemory, EEVM.Database.InMemory.init())
      iex> EEVM.Database.get_balance(db, 0x1234)
      0
  """
  @spec new(module(), term()) :: t()
  def new(impl, state) do
    Code.ensure_loaded(impl)

    if function_exported?(impl, :account, 2) or not function_exported?(impl, :get_account, 2),
      do: %__MODULE__{impl: impl, state: state},
      else: %__MODULE__{impl: EEVM.Database.Legacy, state: {impl, state}}
  end

  @doc """
  Returns the overlay's writes as an `EEVM.StateChanges`.

  ## Example

      iex> db = EEVM.Database.InMemory.new() |> EEVM.Database.set_balance(1, 5)
      iex> %{1 => change} = EEVM.Database.changes(db).accounts
      iex> {change.balance, change.nonce, change.destroyed?}
      {5, 0, false}
  """
  @spec changes(t()) :: StateChanges.t()
  def changes(%__MODULE__{} = db) do
    addresses =
      db.accounts
      |> Map.keys()
      |> Enum.concat(Map.keys(db.storage))
      |> Enum.concat(db.destroyed)
      |> Enum.uniq()

    %StateChanges{accounts: Map.new(addresses, &{&1, change(db, &1)})}
  end

  defp change(db, address) do
    case Map.fetch(db.accounts, address) do
      {:ok, nil} ->
        :destroyed

      _present_or_untouched ->
        account = fetch_account(db, address) || new_account()

        %{
          balance: account.balance,
          nonce: account.nonce,
          code_hash: account.code_hash,
          code: account.code,
          storage: Map.get(db.storage, address, %{}),
          destroyed?: MapSet.member?(db.destroyed, address)
        }
    end
  end

  @doc """
  Commits the overlay to the backend with its `c:commit/2` and returns the
  database with an empty overlay. Returns `{:error, :commit_not_supported}`
  when the backend has no `commit/2`.
  """
  @spec commit(t()) :: {:ok, t()} | {:error, term()}
  def commit(%__MODULE__{impl: impl, state: state} = db) do
    if function_exported?(impl, :commit, 2) do
      with {:ok, new_state} <- impl.commit(state, changes(db)) do
        {:ok, %__MODULE__{impl: impl, state: new_state}}
      end
    else
      {:error, :commit_not_supported}
    end
  end

  @doc false
  # Commits when the backend supports it, for the entry points that do.
  @spec commit_if_supported(t()) :: {:ok, t()} | {:error, {:database, term()}}
  def commit_if_supported(%__MODULE__{} = db) do
    case commit(db) do
      {:ok, db} -> {:ok, db}
      {:error, :commit_not_supported} -> {:ok, db}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  @doc false
  # Runs `fun`, turning a backend read failure into `{:error, {:database, reason}}`.
  @spec catch_read_errors((-> result)) :: result | {:error, {:database, term()}}
        when result: term()
  def catch_read_errors(fun) do
    fun.()
  rescue
    error in ReadError -> {:error, {:database, error.reason}}
  end

  # ---------------------------------------------------------------------------
  # Reads, through the overlay
  # ---------------------------------------------------------------------------

  @doc "Returns `%{balance, nonce, code}` for `address`, or `nil` if it has no account."
  @spec get_account(t(), address()) :: account() | nil
  def get_account(%__MODULE__{} = db, address) do
    case fetch_account(db, address) do
      nil -> nil
      account -> %{balance: account.balance, nonce: account.nonce, code: load_code(db, account)}
    end
  end

  @doc "Returns whether an account exists at `address`."
  @spec account_exists?(t(), address()) :: boolean()
  def account_exists?(%__MODULE__{} = db, address), do: fetch_account(db, address) != nil

  @doc "Returns the code at `address`, or `<<>>`."
  @spec get_code(t(), address()) :: binary()
  def get_code(%__MODULE__{} = db, address) do
    case fetch_account(db, address) do
      nil -> <<>>
      account -> load_code(db, account)
    end
  end

  @doc "Returns the keccak256 hash of the code at `address`; `nil` if it has no account."
  @spec get_code_hash(t(), address()) :: <<_::256>> | nil
  def get_code_hash(%__MODULE__{} = db, address) do
    case fetch_account(db, address) do
      nil -> nil
      account -> account.code_hash
    end
  end

  @doc "Returns the balance of `address` in wei (0 if it has no account)."
  @spec get_balance(t(), address()) :: non_neg_integer()
  def get_balance(%__MODULE__{} = db, address) do
    case fetch_account(db, address) do
      nil -> 0
      account -> account.balance
    end
  end

  @doc "Returns the nonce of `address` (0 if it has no account)."
  @spec get_nonce(t(), address()) :: non_neg_integer()
  def get_nonce(%__MODULE__{} = db, address) do
    case fetch_account(db, address) do
      nil -> 0
      account -> account.nonce
    end
  end

  @doc "Returns whether `address` is empty: zero balance and nonce, and no code (EIP-161)."
  @spec account_empty?(t(), address()) :: boolean()
  def account_empty?(%__MODULE__{} = db, address) do
    case fetch_account(db, address) do
      nil ->
        true

      account ->
        account.balance == 0 and account.nonce == 0 and account.code_hash == @empty_code_hash
    end
  end

  @doc "Returns the storage word at `key` of `address` (0 when unset)."
  @spec storage_load(t(), address(), non_neg_integer()) :: non_neg_integer()
  def storage_load(%__MODULE__{storage: storage} = db, address, key) do
    with {:ok, slots} <- Map.fetch(storage, address),
         {:ok, value} <- Map.fetch(slots, key) do
      value
    else
      :error ->
        if MapSet.member?(db.destroyed, address),
          do: 0,
          else: read!(db.impl.storage(db.state, address, key))
    end
  end

  @doc "Returns the hash of block `number` from the backend, or `nil` when unknown."
  @spec block_hash(t(), non_neg_integer()) :: <<_::256>> | nil
  def block_hash(%__MODULE__{impl: impl, state: state}, number),
    do: read!(impl.block_hash(state, number))

  @doc """
  Returns every address with an account or storage, overlay included.
  Needs the backend's `c:accounts/1`.
  """
  @spec account_addresses(t()) :: [address()]
  def account_addresses(%__MODULE__{impl: impl, state: state} = db) do
    backend =
      if function_exported?(impl, :accounts, 1), do: Enum.to_list(impl.accounts(state)), else: []

    backend
    |> Enum.concat(Map.keys(db.accounts))
    |> Enum.concat(Map.keys(db.storage))
    |> Enum.uniq()
    |> Enum.filter(&(account_exists?(db, &1) or storage_slots(db, &1) != []))
  end

  @doc """
  Returns `{slot, value}` for every set storage slot of `address`, overlay
  included. Needs the backend's `c:storage_slots/2`.
  """
  @spec storage_slots(t(), address()) :: [{non_neg_integer(), non_neg_integer()}]
  def storage_slots(%__MODULE__{impl: impl, state: state} = db, address) do
    backend =
      if not MapSet.member?(db.destroyed, address) and
           function_exported?(impl, :storage_slots, 2),
         do: Map.new(impl.storage_slots(state, address)),
         else: %{}

    backend
    |> Map.merge(Map.get(db.storage, address, %{}))
    |> Enum.reject(fn {_slot, value} -> value == 0 end)
  end

  @doc "Returns the addresses with storage. Deprecated: use `account_addresses/1`."
  @deprecated "Use EEVM.Database.account_addresses/1"
  @spec storage_addresses(t()) :: [address()]
  def storage_addresses(%__MODULE__{} = db),
    do: Enum.filter(account_addresses(db), &(storage_slots(db, &1) != []))

  # ---------------------------------------------------------------------------
  # Writes, to the overlay
  # ---------------------------------------------------------------------------

  @doc "Replaces the account record at `address`; missing fields default to zero and no code."
  @spec put_account(t(), address(), account()) :: t()
  def put_account(%__MODULE__{} = db, address, account) when is_map(account) do
    code = Map.get(account, :code, <<>>)

    put_overlay(db, address, %{
      balance: Map.get(account, :balance, 0),
      nonce: Map.get(account, :nonce, 0),
      code_hash: hash_code(code),
      code: code
    })
  end

  @doc "Deletes the account at `address` and all its storage."
  @spec delete_account(t(), address()) :: t()
  def delete_account(%__MODULE__{} = db, address) do
    %{
      db
      | accounts: Map.put(db.accounts, address, nil),
        storage: Map.delete(db.storage, address),
        destroyed: MapSet.put(db.destroyed, address)
    }
  end

  @doc "Sets the code at `address`."
  @spec put_code(t(), address(), binary()) :: t()
  def put_code(%__MODULE__{} = db, address, code) when is_binary(code),
    do: update_account(db, address, &%{&1 | code: code, code_hash: hash_code(code)})

  @doc "Sets the balance of `address`."
  @spec set_balance(t(), address(), non_neg_integer()) :: t()
  def set_balance(%__MODULE__{} = db, address, balance),
    do: update_account(db, address, &%{&1 | balance: balance})

  @doc "Sets the nonce of `address`."
  @spec set_nonce(t(), address(), non_neg_integer()) :: t()
  def set_nonce(%__MODULE__{} = db, address, nonce),
    do: update_account(db, address, &%{&1 | nonce: nonce})

  @doc "Increments the nonce of `address`."
  @spec increment_nonce(t(), address()) :: t()
  def increment_nonce(%__MODULE__{} = db, address),
    do: update_account(db, address, &%{&1 | nonce: &1.nonce + 1})

  @doc "Moves `amount` wei from `from` to `to`."
  @spec transfer(t(), address(), address(), non_neg_integer()) ::
          {:ok, t()} | {:error, :insufficient_balance}
  def transfer(%__MODULE__{} = db, _from, _to, 0), do: {:ok, db}

  def transfer(%__MODULE__{} = db, from, to, amount) do
    from_balance = get_balance(db, from)

    if from_balance < amount do
      {:error, :insufficient_balance}
    else
      # Credit from the debited state so a self-transfer leaves the balance unchanged.
      debited = set_balance(db, from, from_balance - amount)
      {:ok, set_balance(debited, to, get_balance(debited, to) + amount)}
    end
  end

  @doc "Stores a 256-bit word at `key` of `address`."
  @spec storage_store(t(), address(), non_neg_integer(), non_neg_integer()) :: t()
  def storage_store(%__MODULE__{storage: storage} = db, address, key, value) do
    slots = Map.get(storage, address, %{})
    %{db | storage: Map.put(storage, address, Map.put(slots, key, rem(value, 2 ** 256)))}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @spec fetch_account(t(), address()) :: overlay_account() | nil
  defp fetch_account(%__MODULE__{accounts: accounts} = db, address) do
    case Map.fetch(accounts, address) do
      {:ok, account} -> account
      :error -> backend_account(db, address)
    end
  end

  defp backend_account(%__MODULE__{impl: impl, state: state}, address) do
    case read!(impl.account(state, address)) do
      nil ->
        nil

      %{code: code} = account ->
        %{
          balance: account.balance,
          nonce: account.nonce,
          code: code,
          code_hash: Map.get_lazy(account, :code_hash, fn -> hash_code(code) end)
        }

      %{code_hash: code_hash} = account ->
        %{balance: account.balance, nonce: account.nonce, code_hash: code_hash, code: nil}
    end
  end

  defp load_code(_db, %{code: code}) when is_binary(code), do: code
  defp load_code(_db, %{code_hash: @empty_code_hash}), do: <<>>

  defp load_code(%__MODULE__{impl: impl, state: state}, %{code_hash: hash}),
    do: read!(impl.code(state, hash))

  defp update_account(db, address, fun),
    do: put_overlay(db, address, fun.(fetch_account(db, address) || new_account()))

  defp put_overlay(db, address, account),
    do: %{db | accounts: Map.put(db.accounts, address, account)}

  defp new_account, do: %{balance: 0, nonce: 0, code_hash: @empty_code_hash, code: <<>>}

  defp hash_code(<<>>), do: @empty_code_hash
  defp hash_code(code), do: ExKeccak.hash_256(code)

  defp read!({:ok, value}), do: value
  defp read!({:error, reason}), do: raise(ReadError, reason: reason)
end
