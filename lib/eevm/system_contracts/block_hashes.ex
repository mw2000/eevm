defmodule EEVM.SystemContracts.BlockHashes do
  @moduledoc """
  EIP-2935 historical block hashes contract (activated in Prague).

  Installs the canonical EIP-2935 deployed bytecode at
  `0x0000F90827F1C53a10cb7A02335B175320002935` and drives it through the
  normal executor. At the start of every block the execution layer performs
  a system call (caller = SYSTEM_ADDRESS `0xff..fe`) with the parent block
  hash as 32-byte calldata; the contract stashes the hash in a ring buffer
  of `HISTORY_SERVE_WINDOW = 8191` slots keyed by the parent block number.
  User contracts read past hashes back via a plain `CALL` with a 32-byte
  block number.

  ## API

  - `install/1` — place the deployed bytecode into a `Database`.
  - `commit/3`  — perform the block-start system call that stores a hash.
    Takes the *current* block (number N) plus the hash of its parent
    (block N-1); the contract does the `N - 1` subtraction internally
    before writing to `storage[(N - 1) mod 8191]`. Returns `{:ok, db}`
    on success and `{:error, reason, db}` on execution failure.
  - `lookup/2`  — read a stored hash directly from storage. A slot that
    has never been written returns `:not_found` (distinguishable from a
    genuinely-stored zero only if the caller knows the slot was written).
  """

  alias EEVM.Context.{Block, Contract, Transaction}
  alias EEVM.Database
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter
  alias EEVM.Interpreter.MachineState

  @address 0x0000F90827F1C53A10CB7A02335B175320002935
  @system_address 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE
  @history_serve_window 8191
  @system_call_gas 30_000_000

  # Deployed runtime bytecode from EIP-2935 ("Block hashes from state"). This
  # is the canonical mainnet runtime — extracted from the EIP's deployment
  # bytecode after the 9-byte deployer prefix `60538060095f395ff3`.
  @deployed_code Base.decode16!(
                   "3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500",
                   case: :lower
                 )

  @doc "Canonical deployment address of the historical block hashes contract."
  @spec address() :: non_neg_integer()
  def address, do: @address

  @doc "Caller address used by the execution layer's block-start system call."
  @spec system_address() :: non_neg_integer()
  def system_address, do: @system_address

  @doc "Ring-buffer size for historical block hashes (constant, 8191)."
  @spec history_serve_window() :: pos_integer()
  def history_serve_window, do: @history_serve_window

  @doc "Returns the exact deployed bytecode that the EIP specifies."
  @spec deployed_bytecode() :: binary()
  def deployed_bytecode, do: @deployed_code

  @doc """
  Installs the historical block hashes contract into `db` at the canonical
  address.

  Idempotent — re-installing leaves storage untouched and only ensures the
  code is present.
  """
  @spec install(Database.t()) :: Database.t()
  def install(%Database{} = db) do
    Database.put_code(db, @address, @deployed_code)
  end

  @doc """
  Installs only if EIP-2935 is active in the given hardfork config. Callers
  setting up a pre-Prague genesis get a no-op.
  """
  @spec install_if_enabled(Database.t(), HardforkConfig.t()) :: Database.t()
  def install_if_enabled(%Database{} = db, %HardforkConfig{} = config) do
    if HardforkConfig.enabled?(config, :eip_2935), do: install(db), else: db
  end

  @doc """
  Executes the block-start system call that records `parent_block_hash` as
  the hash for block `block.number - 1`.

  Uses SYSTEM_ADDRESS as the caller so the contract takes its storage branch.
  Returns the updated database, or an error tuple if the call reverted (which
  should never happen with the canonical bytecode, but we surface it rather
  than swallow it).
  """
  @spec commit(Database.t(), Block.t(), <<_::256>>) ::
          {:ok, Database.t()} | {:error, atom(), Database.t()}
  def commit(%Database{} = db, %Block{} = block, parent_block_hash)
      when is_binary(parent_block_hash) and byte_size(parent_block_hash) == 32 do
    final_state =
      @deployed_code
      |> MachineState.new(
        db: db,
        block: block,
        tx: %Transaction{origin: @system_address},
        contract: %Contract{
          address: @address,
          caller: @system_address,
          callvalue: 0,
          calldata: parent_block_hash
        },
        gas: @system_call_gas
      )
      |> Interpreter.run_loop()

    # RETURN and STOP both halt with :stopped in this VM; the distinction is
    # whether return_data was populated. A :reverted status means the contract
    # rejected the call (malformed calldata / bad caller).
    case final_state.status do
      :stopped -> {:ok, final_state.db}
      other -> {:error, other, final_state.db}
    end
  end

  @doc """
  Reads the hash stored at `block_number mod 8191`, directly from the
  contract's storage slot.

  This is a raw storage read: it deliberately does NOT enforce any range
  checks, so callers with no view of the current block number can still
  inspect the ring buffer. A slot that has never been written returns
  `:not_found` (distinguishable from a genuinely-stored zero only if the
  caller knows the slot was written).
  """
  @spec lookup(Database.t(), non_neg_integer()) :: {:ok, non_neg_integer()} | :not_found
  def lookup(%Database{} = db, block_number)
      when is_integer(block_number) and block_number >= 0 do
    index = rem(block_number, @history_serve_window)

    case Database.storage_load(db, @address, index) do
      0 -> :not_found
      hash -> {:ok, hash}
    end
  end
end
