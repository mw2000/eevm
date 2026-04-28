defmodule EEVM.SystemContracts.BlockHashesTest do
  use ExUnit.Case, async: true

  alias EEVM.Context.{Block, Contract, Transaction}
  alias EEVM.Database
  alias EEVM.Database.InMemory
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.MachineState
  alias EEVM.SystemContracts.BlockHashes

  @window 8191

  describe "install/1" do
    test "places the deployed bytecode at the canonical address" do
      db = BlockHashes.install(InMemory.new())

      assert Database.get_code(db, BlockHashes.address()) == BlockHashes.deployed_bytecode()
    end

    test "is idempotent — re-installing leaves storage untouched" do
      db =
        InMemory.new()
        |> BlockHashes.install()
        |> Database.storage_store(BlockHashes.address(), 42, 0xABC)
        |> BlockHashes.install()

      assert Database.storage_load(db, BlockHashes.address(), 42) == 0xABC
    end
  end

  describe "install_if_enabled/2" do
    test "installs under Prague+" do
      db = BlockHashes.install_if_enabled(InMemory.new(), HardforkConfig.new(:prague))
      assert Database.get_code(db, BlockHashes.address()) == BlockHashes.deployed_bytecode()
    end

    test "is a no-op pre-Prague" do
      db = BlockHashes.install_if_enabled(InMemory.new(), HardforkConfig.new(:cancun))
      assert Database.get_code(db, BlockHashes.address()) == <<>>
    end
  end

  describe "commit/3" do
    test "stores the parent hash at slot (block.number - 1) mod 8191" do
      db = BlockHashes.install(InMemory.new())
      block = %Block{number: 1_000_001}
      hash = 0xDEADBEEFCAFEBABE0000000000000000000000000000000000000000FACEFEED

      {:ok, db} = BlockHashes.commit(db, block, hash)

      slot = rem(1_000_000, @window)
      assert Database.storage_load(db, BlockHashes.address(), slot) == hash
    end

    test "lookup/2 round-trips a committed hash" do
      db = BlockHashes.install(InMemory.new())
      hash = 0xFEED0001

      {:ok, db} = BlockHashes.commit(db, %Block{number: 1_000_001}, hash)

      assert BlockHashes.lookup(db, 1_000_000) == {:ok, hash}
    end

    test "lookup/2 returns :not_found for unknown blocks" do
      db = BlockHashes.install(InMemory.new())
      assert BlockHashes.lookup(db, 42) == :not_found
    end

    test "ring buffer overwrites when block numbers collide mod 8191" do
      db = BlockHashes.install(InMemory.new())

      # parent block 1_000 then parent block 1_000 + 8191 — same ring slot.
      {:ok, db} = BlockHashes.commit(db, %Block{number: 1_001}, 0xAAAA)
      {:ok, db} = BlockHashes.commit(db, %Block{number: 1_001 + @window}, 0xBBBB)

      assert BlockHashes.lookup(db, 1_000) == {:ok, 0xBBBB}
      assert BlockHashes.lookup(db, 1_000 + @window) == {:ok, 0xBBBB}
    end
  end

  describe "user CALL to the contract" do
    test "returns the stored block hash when queried for an in-window block" do
      block_number = 1_000_001
      target_block = 1_000_000
      hash = 0x1111111111111111111111111111111111111111111111111111111111111111

      db = BlockHashes.install(InMemory.new())
      {:ok, db} = BlockHashes.commit(db, %Block{number: block_number}, hash)

      final_state = call_contract(db, block_number, target_block)

      assert final_state.status == :stopped
      assert byte_size(final_state.return_data) == 32
      <<returned_hash::unsigned-big-256>> = final_state.return_data
      assert returned_hash == hash
    end

    test "reverts when the requested block is the current block (not in the past)" do
      block_number = 1_000_001
      db = BlockHashes.install(InMemory.new())

      final_state = call_contract(db, block_number, block_number)

      assert final_state.status == :reverted
    end

    test "reverts when the requested block is in the future" do
      block_number = 1_000_001
      db = BlockHashes.install(InMemory.new())

      final_state = call_contract(db, block_number, block_number + 5)

      assert final_state.status == :reverted
    end
  end

  defp call_contract(db, block_number, requested_block) do
    BlockHashes.deployed_bytecode()
    |> MachineState.new(
      db: db,
      block: %Block{number: block_number},
      tx: %Transaction{origin: 0xCAFE},
      contract: %Contract{
        address: BlockHashes.address(),
        caller: 0xCAFE,
        calldata: <<requested_block::unsigned-big-256>>
      },
      gas: 1_000_000
    )
    |> EEVM.Interpreter.run_loop()
  end
end
