defmodule EEVM.SystemContracts.BlockHashes do
  @moduledoc """
  EIP-2935 historical block hashes contract.

  ## EVM Concepts

  The `BLOCKHASH` opcode can only address the previous 256 ancestors of the
  current block. That 256-block window is a protocol-imposed limit that keeps
  clients from having to retain arbitrarily-deep history in order to execute
  contracts. EIP-2935 extends the reachable history to the last 8191 blocks
  without touching the opcode itself — instead, an ordinary contract deployed
  at

      0x0000F90827F1C53a10cb7A02335B175320002935

  exposes the hashes through a plain `CALL`. The `BLOCKHASH` opcode's rules
  are unchanged; dapps that want deeper history do so explicitly by CALLing
  this address.

  At the start of every block the execution client performs a *system call*
  into the contract with the parent block hash as 32-byte calldata, signed as
  coming from the SYSTEM_ADDRESS (`0xff..fe`). The contract notices the
  system caller and stashes the hash in a ring buffer slot keyed by the
  parent block number:

      storage[(block.number - 1) % 8191] = parent_block_hash

  User contracts later `CALL` the same address with a 32-byte block number
  as calldata. The bytecode validates that the calldata is exactly 32 bytes
  and that the requested block is strictly in the past
  (`requested < block.number`); otherwise it reverts. When the upper-bound
  check passes the contract returns `storage[requested mod 8191]`. The
  EIP-canonical bytecode does *not* additionally enforce a lower bound — a
  request that ranges further back than 8191 blocks will simply return
  whatever stale entry currently sits in that ring-buffer slot.

  Activated in Prague.

  ## Design

  We do not invent a custom precompile. Instead we install the exact deployed
  bytecode specified by EIP-2935 at the canonical address and drive it
  through the normal executor — the same code path any user CALL takes. This
  keeps behavior faithful to mainnet and means any future changes to CALL
  semantics come along for free.

  - `install/1` — place the deployed bytecode into a `Database`.
  - `commit/3`  — perform the block-start system call that stores a hash.
  - `lookup/2`  — read a stored hash directly from storage (convenience).

  `commit/3` takes the *current* block (whose `number` is, say, N) plus the
  hash of its parent (block N-1). The contract does the `N - 1` subtraction
  internally before writing to `storage[(N - 1) mod 8191]`, so the caller
  never has to know about the ring-buffer offset.

  `commit/3` returns `{:ok, updated_db}` on success and `{:error, reason, db}`
  on an execution failure; the caller decides what to do about it.

  ## Elixir Learning Notes

  - The deployed bytecode lives as a compile-time constant via `@deployed_code`
    so there is no per-call decoding cost.
  - `install/1` and `commit/3` both work on plain `Database` values — no
    `MachineState` is exposed to callers — keeping the integration surface
    small for higher layers that aren't yet aware of full EVM state.
  - `lookup/2` reads storage directly: a slot that has never been written
    returns `:not_found`, distinguishable from a genuinely-stored zero only
    if the caller knows the slot was written.
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
