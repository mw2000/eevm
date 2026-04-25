defmodule EEVM.SystemContracts.BeaconRoots do
  @moduledoc """
  EIP-4788 beacon block root contract.

  ## EVM Concepts

  Before Cancun the consensus-layer (CL) beacon block root was invisible to
  the EVM. EIP-4788 bridges that gap with an ordinary contract deployed at a
  well-known address:

      0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02

  At the start of every block the execution client performs a *system call*
  into this contract with the parent beacon-block root as calldata, signed as
  coming from the SYSTEM_ADDRESS (`0xff..fe`). The contract keys the root by
  the current block timestamp and stashes it in a ring buffer of
  `HISTORY_BUFFER_LENGTH = 8191` slots. User contracts later `CALL` the same
  address with a 32-byte timestamp to read back the root.

  Storage layout (per the EIP):

  - `storage[timestamp % 8191]`           = timestamp
  - `storage[(timestamp % 8191) + 8191]`  = beacon_root

  On read, the contract verifies the timestamp slot matches the queried
  timestamp (so collisions from the ring buffer return an empty result
  instead of a stale root).

  ## Design

  We do not invent a custom precompile. Instead we install the exact deployed
  bytecode specified by the EIP at the canonical address and drive it through
  the normal executor — the same code path any CALL would take. This keeps
  behavior faithful to mainnet and means any future changes to CALL semantics
  come along for free.

  - `install/1` — place the deployed bytecode into a `Database`.
  - `commit/3`  — perform the block-start system call that stores a root.
  - `lookup/2`  — read a stored root directly from storage (convenience).

  `commit/3` returns `{:ok, updated_db}` on success and `{:error, reason, db}`
  on an execution failure; the caller decides what to do about it.

  ## Elixir Learning Notes

  - The deployed bytecode lives as a compile-time constant via `@deployed_code`
    so there is no per-call decoding cost.
  - `install/1` and `commit/3` both work on plain `Database` values — no
    `MachineState` is exposed to callers — keeping the integration surface
    small for higher layers that aren't yet aware of full EVM state.
  """

  alias EEVM.{Database, HardforkConfig, Interpreter}
  alias EEVM.Interpreter.MachineState
  alias EEVM.Context.{Block, Contract, Transaction}

  @address 0x000F3DF6D732807EF1319FB7B8BB8522D0BEAC02
  @system_address 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE
  @history_buffer_length 8191
  @system_call_gas 30_000_000

  # Deployed runtime bytecode from EIP-4788, section "Deployment".
  @deployed_code Base.decode16!(
                   "3373FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE14604D57602036146024" <>
                     "575F5FFD5B5F35801560495762001FFF810690815414603C575F5FFD5B62001F" <>
                     "FF01545F5260205FF35B5F5FFD5B62001FFF42064281555F359062001FFF0155" <>
                     "00"
                 )

  @doc "Canonical deployment address of the beacon-roots contract."
  @spec address() :: non_neg_integer()
  def address, do: @address

  @doc "Caller address used by the execution layer's block-start system call."
  @spec system_address() :: non_neg_integer()
  def system_address, do: @system_address

  @doc "Ring-buffer size for beacon-root history (constant, 8191)."
  @spec history_buffer_length() :: pos_integer()
  def history_buffer_length, do: @history_buffer_length

  @doc "Returns the exact deployed bytecode that the EIP specifies."
  @spec deployed_bytecode() :: binary()
  def deployed_bytecode, do: @deployed_code

  @doc """
  Installs the beacon-roots contract into `db` at the canonical address.

  Idempotent — re-installing leaves storage untouched and only ensures the
  code is present.
  """
  @spec install(Database.t()) :: Database.t()
  def install(%Database{} = db) do
    Database.put_code(db, @address, @deployed_code)
  end

  @doc """
  Installs only if EIP-4788 is active in the given hardfork config. Callers
  setting up a pre-Cancun genesis get a no-op.
  """
  @spec install_if_enabled(Database.t(), HardforkConfig.t()) :: Database.t()
  def install_if_enabled(%Database{} = db, %HardforkConfig{} = config) do
    if HardforkConfig.enabled?(config, :eip_4788), do: install(db), else: db
  end

  @doc """
  Executes the block-start system call that records `beacon_root` under
  `block.timestamp`.

  Uses SYSTEM_ADDRESS as the caller so the contract takes its storage branch.
  Returns the updated database, or an error tuple if the call reverted (which
  should never happen with the canonical bytecode, but we surface it rather
  than swallow it).
  """
  @spec commit(Database.t(), Block.t(), non_neg_integer()) ::
          {:ok, Database.t()} | {:error, atom(), Database.t()}
  def commit(%Database{} = db, %Block{} = block, beacon_root)
      when is_integer(beacon_root) and beacon_root >= 0 do
    calldata = <<beacon_root::unsigned-big-256>>

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
          calldata: calldata
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
  Reads a previously-committed beacon root by timestamp, directly from the
  contract's storage slots.

  Returns `{:ok, root}` when the slot at `timestamp % 8191` matches
  `timestamp` (i.e. no ring-buffer collision), and `:not_found` otherwise.
  """
  @spec lookup(Database.t(), non_neg_integer()) :: {:ok, non_neg_integer()} | :not_found
  def lookup(%Database{} = db, timestamp) when is_integer(timestamp) and timestamp >= 0 do
    index = rem(timestamp, @history_buffer_length)
    stored_ts = Database.storage_load(db, @address, index)

    if stored_ts == timestamp do
      {:ok, Database.storage_load(db, @address, index + @history_buffer_length)}
    else
      :not_found
    end
  end
end
