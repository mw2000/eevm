defmodule EEVM.Interpreter.MachineState.EIP3651Test do
  use ExUnit.Case, async: true
  import EEVM.TestSupport.MachineHelpers

  alias EEVM.BlockEnv
  alias EEVM.Config
  alias EEVM.Context.Contract
  alias EEVM.Database.InMemory
  alias EEVM.Interpreter.MachineState
  alias EEVM.TxEnv

  describe "EIP-3651 coinbase pre-warming" do
    test "new machine state pre-warms non-zero coinbase" do
      block = BlockEnv.new(coinbase: 0xBEEF)

      state = MachineState.new(<<0x00>>, block: block)

      assert MapSet.member?(state.substate.accessed_addresses, block.coinbase)
    end

    test "new machine state pre-warms zero coinbase by default" do
      block = BlockEnv.new()

      state = MachineState.new(<<0x00>>, block: block)

      assert MapSet.member?(state.substate.accessed_addresses, block.coinbase)
    end

    test "existing pre-warmed addresses remain present" do
      contract = Contract.new(address: 0xAA, caller: 0xBB)
      tx = TxEnv.new(origin: 0xCC)

      state = MachineState.new(<<0x00>>, contract: contract, tx: tx)

      assert MapSet.member?(state.substate.accessed_addresses, contract.address)
      assert MapSet.member?(state.substate.accessed_addresses, contract.caller)
      assert MapSet.member?(state.substate.accessed_addresses, tx.origin)
      assert MapSet.member?(state.substate.accessed_addresses, 0x01)
    end

    test "BALANCE access to COINBASE is charged at warm rate (100 gas)" do
      initial_gas = 10_000
      block = BlockEnv.new(coinbase: 0xBEEF)
      world_state = InMemory.new(accounts: %{0xBEEF => %{balance: 123}})
      code = <<0x41, 0x31, 0x00>>

      result = run_code(code, gas: initial_gas, block: block, db: world_state)

      assert result.frame.gas == initial_gas - 2 - 100
      refute result.frame.gas == initial_gas - 2 - 2600
    end

    test "custom precompile addresses are pre-warmed" do
      config = Config.new() |> Config.register_precompile(0x100, EEVM.Precompiles.Identity)

      state = MachineState.new(<<0x00>>, config: config)

      assert MapSet.member?(state.substate.accessed_addresses, 0x100)
    end
  end
end
