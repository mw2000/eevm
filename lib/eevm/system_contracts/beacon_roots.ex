defmodule EEVM.SystemContracts.BeaconRoots do
  @moduledoc """
  EIP-4788 beacon block root contract (activated in Cancun).

  Installs the canonical EIP-4788 deployed bytecode at
  `0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02` and drives it through the
  normal executor. At the start of every block the execution layer performs
  a system call (caller = SYSTEM_ADDRESS `0xff..fe`) with the parent
  beacon-block root as calldata; the contract keys it by `block.timestamp`
  in a ring buffer of `HISTORY_BUFFER_LENGTH = 8191` slots. User contracts
  read past roots back via a plain `CALL` with a 32-byte timestamp.

  Storage layout (per the EIP):

  - `storage[timestamp % 8191]`           = timestamp
  - `storage[(timestamp % 8191) + 8191]`  = beacon_root

  On read, the contract verifies the timestamp slot matches the queried
  timestamp (so ring-buffer collisions return empty rather than a stale root).

  ## API

  - `install/1` — place the deployed bytecode into a `Database`.
  - `commit/3`  — perform the block-start system call that stores a root.
    Returns `{:ok, db}` on success and `{:error, reason, db}` on execution
    failure.
  - `lookup/2`  — read a stored root directly from storage (`{:ok, root}`
    when the timestamp slot matches, `:not_found` otherwise).
  """

  alias EEVM.Context.{Block, Contract, Transaction}
  alias EEVM.Database
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter
  alias EEVM.Interpreter.MachineState

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
