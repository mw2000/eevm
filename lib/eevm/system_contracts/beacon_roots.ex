defmodule EEVM.SystemContracts.BeaconRoots do
  @moduledoc """
  EIP-4788 beacon block root (Cancun+).

  Bridges the consensus-layer beacon root into the EVM. A contract at
  `0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02` holds an 8191-slot ring buffer
  keyed by `block.timestamp`. The block-start system call from `SYSTEM_ADDRESS`
  writes:

      storage[timestamp mod 8191]          = timestamp
      storage[(timestamp mod 8191) + 8191] = beacon_root

  On read the contract checks the timestamp slot matches the query, so
  ring-buffer collisions return empty rather than a stale root.

  Three entry points (`install/1`, `commit/3`, `lookup/2`) on a plain
  `Database`. `commit/3` runs the canonical bytecode through the regular
  interpreter and surfaces unexpected reverts as `{:error, status, db}`.
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

  @doc "Writes the canonical bytecode at the contract address. Idempotent."
  @spec install(Database.t()) :: Database.t()
  def install(%Database{} = db) do
    Database.put_code(db, @address, @deployed_code)
  end

  @doc "No-op for pre-Cancun configs; otherwise calls `install/1`."
  @spec install_if_enabled(Database.t(), HardforkConfig.t()) :: Database.t()
  def install_if_enabled(%Database{} = db, %HardforkConfig{} = config) do
    if HardforkConfig.enabled?(config, :eip_4788), do: install(db), else: db
  end

  @doc """
  Block-start system call: records `beacon_root` under `block.timestamp`.

  Caller is SYSTEM_ADDRESS so the contract takes its storage branch. Surfaces
  unexpected reverts as `{:error, status, db}` rather than swallowing them.
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

    case final_state.status do
      :stopped -> {:ok, final_state.db}
      other -> {:error, other, final_state.db}
    end
  end

  @doc """
  Looks up a beacon root by timestamp. Returns `{:ok, root}` when the slot
  at `timestamp mod 8191` still holds `timestamp`; `:not_found` on a
  ring-buffer collision or missing entry.
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
