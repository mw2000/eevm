defmodule EEVM.SystemContracts.BlockHashes do
  @moduledoc """
  EIP-2935 historical block hashes (Prague+).

  Extends reachable history to 8191 blocks without changing `BLOCKHASH`. A
  contract at `0x0000F90827F1C53a10cb7A02335B175320002935` holds an 8191-slot
  ring buffer (`storage[(N-1) mod 8191] = hash(N-1)`) and is updated by a
  block-start system call from `SYSTEM_ADDRESS` (`0xff..fe`).

  Three entry points, all operating on a plain `Database`:

  - `install/1` — write the canonical EIP-2935 runtime bytecode at the
    canonical address (idempotent — leaves storage untouched).
  - `commit/3` — execute the block-start system call recording
    `parent_block_hash` for `block.number - 1`. Returns `{:error, status, db}`
    if the canonical bytecode rejects the call.
  - `lookup/2` — direct ring-buffer read; `:not_found` for a never-written
    slot (indistinguishable from a stored zero without external context).

  `commit/3` runs the canonical bytecode through the regular interpreter so
  CALL-semantic changes are inherited automatically rather than re-implemented.
  """

  alias EEVM.{Database, HardforkConfig, Interpreter}
  alias EEVM.Interpreter.MachineState
  alias EEVM.Context.{Block, Contract, Transaction}

  @address 0x0000F90827F1C53A10CB7A02335B175320002935
  @system_address 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE
  @history_serve_window 8191
  @system_call_gas 30_000_000

  # Canonical EIP-2935 runtime, after the 9-byte deployer prefix 60538060095f395ff3.
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

  @doc "Writes the canonical bytecode at the contract address. Idempotent."
  @spec install(Database.t()) :: Database.t()
  def install(%Database{} = db) do
    Database.put_code(db, @address, @deployed_code)
  end

  @doc "No-op for pre-Prague configs; otherwise calls `install/1`."
  @spec install_if_enabled(Database.t(), HardforkConfig.t()) :: Database.t()
  def install_if_enabled(%Database{} = db, %HardforkConfig{} = config) do
    if HardforkConfig.enabled?(config, :eip_2935), do: install(db), else: db
  end

  @doc """
  Block-start system call: records `parent_block_hash` for `block.number - 1`.

  Caller is SYSTEM_ADDRESS so the contract takes its storage branch. Surfaces
  unexpected reverts as `{:error, status, db}` rather than swallowing them.
  """
  @spec commit(Database.t(), Block.t(), non_neg_integer()) ::
          {:ok, Database.t()} | {:error, atom(), Database.t()}
  def commit(%Database{} = db, %Block{} = block, parent_block_hash)
      when is_integer(parent_block_hash) and parent_block_hash >= 0 do
    calldata = <<parent_block_hash::unsigned-big-256>>

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
  Raw read of `storage[block_number mod 8191]`. No range checks — callers
  without a current block number can still inspect the ring buffer. Returns
  `:not_found` for an unwritten slot.
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
