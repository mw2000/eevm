defmodule EEVM.Interpreter.Instructions.SelfdestructTest do
  use ExUnit.Case, async: true

  alias EEVM.Context.Contract
  alias EEVM.Database
  alias EEVM.Database.InMemory
  alias EEVM.Gas.Static
  alias EEVM.WorldState

  describe "SELFDESTRUCT (0xFF) - EIP-6780 post-Cancun" do
    test "transfers balance to beneficiary" do
      world_state =
        WorldState.new(%{
          0xAA => %{balance: 100},
          0xBB => %{balance: 50}
        })

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      assert result.status == :stopped
      assert Database.get_balance(result.db, 0xAA) == 0
      assert Database.get_balance(result.db, 0xBB) == 150
    end

    test "halts execution after SELFDESTRUCT" do
      world_state = WorldState.new(%{0xAA => %{balance: 10}})
      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF, 0x60, 0x01>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == []
    end

    test "halts exceptionally in static context" do
      code = <<0x60, 0xBB, 0xFF>>
      result = EEVM.execute(code, is_static: true, gas: 1_000_000)
      assert result.status == {:error, :static_state_modification}
      assert result.frame.gas == 0
    end

    test "self-destruct to self keeps balance unchanged" do
      world_state = WorldState.new(%{0xAA => %{balance: 100}})
      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xAA, 0xFF>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      assert result.status == :stopped
      assert Database.get_balance(result.db, 0xAA) == 100
    end

    test "zero balance self-destruct costs 5000 gas" do
      world_state =
        WorldState.new(%{
          0xAA => %{balance: 0},
          0xBB => %{balance: 0}
        })

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      assert result.status == :stopped
      # 5,000 static plus 2,600 for the cold beneficiary (EIP-2929).
      expected_gas = 1_000_000 - Static.static_cost(0x60) - 5000 - 2_600
      assert result.frame.gas == expected_gas
    end

    test "charges extra 25000 gas for new beneficiary with value" do
      world_state = WorldState.new(%{0xAA => %{balance: 100}})
      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xCC, 0xFF>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      assert result.status == :stopped
      # 5,000 static plus 2,600 for the cold beneficiary (EIP-2929).
      expected_gas = 1_000_000 - Static.static_cost(0x60) - 5000 - 2_600 - 25_000
      assert result.frame.gas == expected_gas
      assert Database.get_balance(result.db, 0xCC) == 100
    end

    test "no extra gas for a non-empty beneficiary with value" do
      world_state =
        WorldState.new(%{
          0xAA => %{balance: 100},
          0xBB => %{balance: 1}
        })

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      # 5,000 static plus 2,600 for the cold beneficiary (EIP-2929).
      expected_gas = 1_000_000 - Static.static_cost(0x60) - 5000 - 2_600
      assert result.frame.gas == expected_gas
    end

    test "no extra gas for new beneficiary with zero value" do
      world_state = WorldState.new(%{0xAA => %{balance: 0}})
      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xCC, 0xFF>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      # 5,000 static plus 2,600 for the cold beneficiary (EIP-2929).
      expected_gas = 1_000_000 - Static.static_cost(0x60) - 5000 - 2_600
      assert result.frame.gas == expected_gas
    end

    test "charges cold access for the beneficiary only when it is cold (EIP-2929)" do
      world_state = WorldState.new(%{0xAA => %{balance: 0}, 0xBB => %{balance: 0}})
      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      run =
        &EEVM.execute(code, [world_state: world_state, contract: contract, gas: 100_000] ++ &1)

      assert run.([]).frame.gas == 100_000 - 3 - 5000 - 2_600
      assert run.(accessed_addresses: MapSet.new([0xAA, 0xBB])).frame.gas == 100_000 - 3 - 5000
      # Before Berlin there is no access-list surcharge.
      assert run.(hardfork: :istanbul).frame.gas == 100_000 - 3 - 5000
    end

    test "contract code/nonce/storage preserved (post-Cancun, not created this tx)" do
      world_state =
        WorldState.new(%{
          0xAA => %{balance: 50, code: <<0x60, 0x01>>, nonce: 5},
          0xBB => %{balance: 0}
        })

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      assert result.status == :stopped
      assert Database.get_code(result.db, 0xAA) == <<0x60, 0x01>>
      assert Database.get_nonce(result.db, 0xAA) == 5
      assert Database.get_balance(result.db, 0xAA) == 0
      assert Database.get_balance(result.db, 0xBB) == 50
    end

    test "EIP-6780: full deletion when contract was created in same tx" do
      world_state =
        WorldState.new(%{
          0xAA => %{balance: 100, code: <<0x60, 0x01>>, nonce: 3},
          0xBB => %{balance: 50}
        })

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      result =
        EEVM.execute(code,
          world_state: world_state,
          contract: contract,
          created_addresses: MapSet.new([0xAA]),
          gas: 1_000_000
        )

      assert result.status == :stopped
      assert Database.get_account(result.db, 0xAA) == nil
      assert Database.account_exists?(result.db, 0xAA) == false
      assert Database.get_balance(result.db, 0xBB) == 150
    end

    test "EIP-6780: full deletion to self when created in same tx burns balance" do
      world_state = WorldState.new(%{0xAA => %{balance: 100, code: <<0x60, 0x01>>, nonce: 1}})
      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xAA, 0xFF>>

      result =
        EEVM.execute(code,
          world_state: world_state,
          contract: contract,
          created_addresses: MapSet.new([0xAA]),
          gas: 1_000_000
        )

      assert result.status == :stopped
      assert Database.get_account(result.db, 0xAA) == nil
    end

    test "EIP-6780: not created this tx preserves account (only transfers balance)" do
      world_state =
        WorldState.new(%{
          0xAA => %{balance: 75, code: <<0xFE>>, nonce: 10},
          0xCC => %{balance: 0}
        })

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xCC, 0xFF>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      assert result.status == :stopped
      assert Database.account_exists?(result.db, 0xAA) == true
      assert Database.get_code(result.db, 0xAA) == <<0xFE>>
      assert Database.get_nonce(result.db, 0xAA) == 10
      assert Database.get_balance(result.db, 0xAA) == 0
      assert Database.get_balance(result.db, 0xCC) == 75
    end
  end

  # SELFDESTRUCT marks the account; it is deleted, storage included, only when
  # the transaction ends (Yellow Paper A_s, geth StateDB.Finalise).
  describe "SELFDESTRUCT (0xFF) - deletion at the end of the transaction" do
    # CALL `address` with no value or data, POP
    defp call(address),
      do:
        <<0x60, 0, 0x60, 0, 0x60, 0, 0x60, 0, 0x60, 0, 0x60, address, 0x61, 0xFF, 0xFF, 0xF1,
          0x50>>

    test "pre-Cancun, the code stays until the transaction ends" do
      world_state = WorldState.new(%{0xAA => %{balance: 10, code: <<0x60, 0xBB, 0xFF>>}})
      # CALL 0xAA, then EXTCODESIZE(0xAA)
      code = call(0xAA) <> <<0x60, 0xAA, 0x3B, 0x00>>

      result = EEVM.execute(code, world_state: world_state, hardfork: :shanghai)

      assert EEVM.stack_values(result) == [3]
      refute Database.account_exists?(result.db, 0xAA)
      assert Database.get_balance(result.db, 0xBB) == 10
    end

    test "deleting the account also deletes its storage" do
      db =
        InMemory.new(
          accounts: %{0xAA => %{balance: 0, code: <<0x60, 0xBB, 0xFF>>}},
          storage: %{0xAA => %{0 => 1}}
        )

      result = EEVM.execute(call(0xAA) <> <<0x00>>, db: db, hardfork: :shanghai)

      refute Database.account_exists?(result.db, 0xAA)
      assert Database.storage_load(result.db, 0xAA, 0) == 0
    end

    test "a SELFDESTRUCT inside a reverted frame deletes nothing" do
      world_state =
        WorldState.new(%{
          0xAA => %{balance: 10, code: <<0x60, 0xCC, 0xFF>>},
          # CALL 0xAA, then REVERT
          0xBB => %{code: call(0xAA) <> <<0x60, 0, 0x60, 0, 0xFD>>}
        })

      result = EEVM.execute(call(0xBB) <> <<0x00>>, world_state: world_state, hardfork: :shanghai)

      assert Database.get_code(result.db, 0xAA) == <<0x60, 0xCC, 0xFF>>
      assert Database.get_balance(result.db, 0xAA) == 10
    end
  end

  describe "SELFDESTRUCT new-account charge by hardfork" do
    # 0xAA (balance 100) self-destructs to 0xBB, which exists but is empty
    # (EIP-161: no code, zero nonce and balance). Gas used minus PUSH1 and the
    # fork's SELFDESTRUCT static cost.
    defp new_account_charge(fork) do
      world_state = WorldState.new(%{0xAA => %{balance: 100}, 0xBB => %{balance: 0}})
      contract = Contract.new(address: 0xAA)

      result =
        EEVM.execute(<<0x60, 0xBB, 0xFF>>,
          world_state: world_state,
          contract: contract,
          gas: 100_000,
          hardfork: fork
        )

      100_000 - result.frame.gas - 3 - Static.static_cost(0xFF, fork)
    end

    test "nothing before EIP-150; 25,000 only for a missing account until EIP-161" do
      assert new_account_charge(:homestead) == 0
      assert new_account_charge(:tangerine_whistle) == 0
    end

    test "from EIP-161 an existing but empty beneficiary receiving value costs 25,000" do
      assert new_account_charge(:spurious_dragon) == 25_000
    end
  end
end
