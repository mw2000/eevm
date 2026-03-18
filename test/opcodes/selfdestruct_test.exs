defmodule EEVM.Opcodes.SelfdestructTest do
  use ExUnit.Case, async: true

  alias EEVM.WorldState
  alias EEVM.Context.Contract
  alias EEVM.Gas.Static

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
      assert WorldState.get_balance(result.world_state, 0xAA) == 0
      assert WorldState.get_balance(result.world_state, 0xBB) == 150
    end

    test "halts execution after SELFDESTRUCT" do
      world_state = WorldState.new(%{0xAA => %{balance: 10}})
      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF, 0x60, 0x01>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == []
    end

    test "reverts in static context" do
      code = <<0x60, 0xBB, 0xFF>>
      result = EEVM.execute(code, is_static: true, gas: 1_000_000)
      assert result.status == :reverted
    end

    test "self-destruct to self keeps balance unchanged" do
      world_state = WorldState.new(%{0xAA => %{balance: 100}})
      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xAA, 0xFF>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      assert result.status == :stopped
      assert WorldState.get_balance(result.world_state, 0xAA) == 100
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
      expected_gas = 1_000_000 - Static.static_cost(0x60) - 5000
      assert result.gas == expected_gas
    end

    test "charges extra 25000 gas for new beneficiary with value" do
      world_state = WorldState.new(%{0xAA => %{balance: 100}})
      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xCC, 0xFF>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      assert result.status == :stopped
      expected_gas = 1_000_000 - Static.static_cost(0x60) - 5000 - 25_000
      assert result.gas == expected_gas
      assert WorldState.get_balance(result.world_state, 0xCC) == 100
    end

    test "no extra gas for existing beneficiary with value" do
      world_state =
        WorldState.new(%{
          0xAA => %{balance: 100},
          0xBB => %{balance: 0}
        })

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      expected_gas = 1_000_000 - Static.static_cost(0x60) - 5000
      assert result.gas == expected_gas
    end

    test "no extra gas for new beneficiary with zero value" do
      world_state = WorldState.new(%{0xAA => %{balance: 0}})
      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xCC, 0xFF>>

      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 1_000_000)

      expected_gas = 1_000_000 - Static.static_cost(0x60) - 5000
      assert result.gas == expected_gas
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
      assert WorldState.get_code(result.world_state, 0xAA) == <<0x60, 0x01>>
      assert WorldState.get_nonce(result.world_state, 0xAA) == 5
      assert WorldState.get_balance(result.world_state, 0xAA) == 0
      assert WorldState.get_balance(result.world_state, 0xBB) == 50
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
      assert WorldState.get_account(result.world_state, 0xAA) == nil
      assert WorldState.account_exists?(result.world_state, 0xAA) == false
      assert WorldState.get_balance(result.world_state, 0xBB) == 150
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
      assert WorldState.get_account(result.world_state, 0xAA) == nil
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
      assert WorldState.account_exists?(result.world_state, 0xAA) == true
      assert WorldState.get_code(result.world_state, 0xAA) == <<0xFE>>
      assert WorldState.get_nonce(result.world_state, 0xAA) == 10
      assert WorldState.get_balance(result.world_state, 0xAA) == 0
      assert WorldState.get_balance(result.world_state, 0xCC) == 75
    end
  end
end
