defmodule EEVM.MachineState.EIP3651Test do
  use ExUnit.Case, async: true

  alias EEVM.MachineState
  alias EEVM.Config
  alias EEVM.WorldState
  alias EEVM.Context.{Block, Contract, Transaction}

  describe "EIP-3651 coinbase pre-warming" do
    test "new machine state pre-warms non-zero coinbase" do
      block = Block.new(coinbase: 0xBEEF)

      state = MachineState.new(<<0x00>>, block: block)

      assert MapSet.member?(state.accessed_addresses, block.coinbase)
    end

    test "new machine state pre-warms zero coinbase by default" do
      block = Block.new()

      state = MachineState.new(<<0x00>>, block: block)

      assert MapSet.member?(state.accessed_addresses, block.coinbase)
    end

    test "existing pre-warmed addresses remain present" do
      contract = Contract.new(address: 0xAA, caller: 0xBB)
      tx = Transaction.new(origin: 0xCC)

      state = MachineState.new(<<0x00>>, contract: contract, tx: tx)

      assert MapSet.member?(state.accessed_addresses, contract.address)
      assert MapSet.member?(state.accessed_addresses, contract.caller)
      assert MapSet.member?(state.accessed_addresses, tx.origin)
      assert MapSet.member?(state.accessed_addresses, 0x01)
    end

    test "BALANCE access to COINBASE is charged at warm rate (100 gas)" do
      initial_gas = 10_000
      block = Block.new(coinbase: 0xBEEF)
      world_state = WorldState.new(%{0xBEEF => %{balance: 123}})
      code = <<0x41, 0x31, 0x00>>

      result = EEVM.execute(code, gas: initial_gas, block: block, world_state: world_state)

      assert result.gas == initial_gas - 2 - 100
      refute result.gas == initial_gas - 2 - 2600
    end

    test "custom precompile addresses are pre-warmed" do
      config = Config.new() |> Config.register_precompile(0x100, EEVM.Precompiles.Identity)

      state = MachineState.new(<<0x00>>, config: config)

      assert MapSet.member?(state.accessed_addresses, 0x100)
    end
  end
end
