defmodule EEVM.SystemContracts.BeaconRootsTest do
  use ExUnit.Case, async: true

  alias EEVM.Database.InMemory
  alias EEVM.{Database, HardforkConfig}
  alias EEVM.Interpreter.MachineState
  alias EEVM.Context.{Block, Contract, Transaction}
  alias EEVM.SystemContracts.BeaconRoots

  @history 8191

  describe "install/1" do
    test "places the deployed bytecode at the canonical address" do
      db = BeaconRoots.install(InMemory.new())

      assert Database.get_code(db, BeaconRoots.address()) == BeaconRoots.deployed_bytecode()
    end

    test "is idempotent — re-installing leaves storage untouched" do
      db =
        InMemory.new()
        |> BeaconRoots.install()
        |> Database.storage_store(BeaconRoots.address(), 42, 0xABC)
        |> BeaconRoots.install()

      assert Database.storage_load(db, BeaconRoots.address(), 42) == 0xABC
    end
  end

  describe "install_if_enabled/2" do
    test "installs under Cancun+" do
      db = BeaconRoots.install_if_enabled(InMemory.new(), HardforkConfig.new(:cancun))
      assert Database.get_code(db, BeaconRoots.address()) == BeaconRoots.deployed_bytecode()
    end

    test "is a no-op pre-Cancun" do
      db = BeaconRoots.install_if_enabled(InMemory.new(), HardforkConfig.new(:shanghai))
      assert Database.get_code(db, BeaconRoots.address()) == <<>>
    end
  end

  describe "commit/3" do
    test "stores timestamp and root in the ring-buffer slots" do
      db = BeaconRoots.install(InMemory.new())
      block = %Block{timestamp: 1_700_000_000}
      root = 0xDEADBEEFCAFEBABE0000000000000000000000000000000000000000FACEFEED

      {:ok, db} = BeaconRoots.commit(db, block, root)

      index = rem(1_700_000_000, @history)
      assert Database.storage_load(db, BeaconRoots.address(), index) == 1_700_000_000
      assert Database.storage_load(db, BeaconRoots.address(), index + @history) == root
    end

    test "lookup/2 round-trips a committed root" do
      db = BeaconRoots.install(InMemory.new())
      block = %Block{timestamp: 1_700_000_000}
      root = 0xFEED0001

      {:ok, db} = BeaconRoots.commit(db, block, root)

      assert BeaconRoots.lookup(db, 1_700_000_000) == {:ok, root}
    end

    test "lookup/2 returns :not_found for unknown timestamps" do
      db = BeaconRoots.install(InMemory.new())
      assert BeaconRoots.lookup(db, 42) == :not_found
    end

    test "ring buffer overwrites when timestamps collide mod 8191" do
      db = BeaconRoots.install(InMemory.new())

      {:ok, db} = BeaconRoots.commit(db, %Block{timestamp: 1_000}, 0xAAAA)
      {:ok, db} = BeaconRoots.commit(db, %Block{timestamp: 1_000 + @history}, 0xBBBB)

      # The older timestamp now fails the verify check — ring slot belongs to the newer one.
      assert BeaconRoots.lookup(db, 1_000) == :not_found
      assert BeaconRoots.lookup(db, 1_000 + @history) == {:ok, 0xBBBB}
    end
  end

  describe "user CALL to the contract" do
    test "returns the stored beacon root when queried by timestamp" do
      timestamp = 1_700_000_000

      root =
        0x1111111111111111111111111111111111111111111111111111111111111111

      db = BeaconRoots.install(InMemory.new())
      {:ok, db} = BeaconRoots.commit(db, %Block{timestamp: timestamp}, root)

      # Execute the contract directly as a user would via CALL: non-system caller,
      # 32-byte timestamp calldata. The bytecode must MSTORE+RETURN the root.
      final_state =
        BeaconRoots.deployed_bytecode()
        |> MachineState.new(
          db: db,
          block: %Block{timestamp: timestamp},
          tx: %Transaction{origin: 0xCAFE},
          contract: %Contract{
            address: BeaconRoots.address(),
            caller: 0xCAFE,
            calldata: <<timestamp::unsigned-big-256>>
          },
          gas: 1_000_000
        )
        |> EEVM.Interpreter.run_loop()

      assert final_state.status == :stopped
      assert byte_size(final_state.return_data) == 32
      <<returned_root::unsigned-big-256>> = final_state.return_data
      assert returned_root == root
    end

    test "reverts on an unknown timestamp" do
      db = BeaconRoots.install(InMemory.new())

      final_state =
        BeaconRoots.deployed_bytecode()
        |> MachineState.new(
          db: db,
          contract: %Contract{
            address: BeaconRoots.address(),
            caller: 0xCAFE,
            calldata: <<999::unsigned-big-256>>
          },
          gas: 1_000_000
        )
        |> EEVM.Interpreter.run_loop()

      assert final_state.status == :reverted
    end
  end
end
