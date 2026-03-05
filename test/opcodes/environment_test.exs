defmodule EEVM.Opcodes.EnvironmentTest do
  use ExUnit.Case, async: true

  alias EEVM.Context.{Transaction, Block, Contract}

  describe "Environment Opcodes" do
    test "ADDRESS pushes current contract address" do
      contract = Contract.new(address: 0xCAFE)
      # ADDRESS, STOP
      code = <<0x30, 0x00>>
      result = EEVM.execute(code, contract: contract)
      assert EEVM.stack_values(result) == [0xCAFE]
    end

    test "CALLER pushes msg.sender" do
      contract = Contract.new(caller: 0xDEAD)
      code = <<0x33, 0x00>>
      result = EEVM.execute(code, contract: contract)
      assert EEVM.stack_values(result) == [0xDEAD]
    end

    test "ORIGIN pushes tx.origin" do
      tx = Transaction.new(origin: 0xBEEF)
      code = <<0x32, 0x00>>
      result = EEVM.execute(code, tx: tx)
      assert EEVM.stack_values(result) == [0xBEEF]
    end

    test "CALLVALUE pushes msg.value" do
      contract = Contract.new(callvalue: 1_000_000)
      code = <<0x34, 0x00>>
      result = EEVM.execute(code, contract: contract)
      assert EEVM.stack_values(result) == [1_000_000]
    end

    test "CALLDATASIZE pushes length of calldata" do
      contract = Contract.new(calldata: <<1, 2, 3, 4>>)
      code = <<0x36, 0x00>>
      result = EEVM.execute(code, contract: contract)
      assert EEVM.stack_values(result) == [4]
    end

    test "CALLDATASIZE is 0 with no calldata" do
      code = <<0x36, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "CALLDATALOAD reads 32 bytes from calldata" do
      # 32 bytes of calldata, load from offset 0
      calldata = <<0::248, 42>>
      contract = Contract.new(calldata: calldata)
      # PUSH1 0, CALLDATALOAD, STOP
      code = <<0x60, 0, 0x35, 0x00>>
      result = EEVM.execute(code, contract: contract)
      assert EEVM.stack_values(result) == [42]
    end

    test "CALLDATALOAD pads with zeros past end" do
      # 4 bytes of calldata, load from offset 0 — pads 28 zeros on right
      calldata = <<0xFF, 0xFF, 0xFF, 0xFF>>
      contract = Contract.new(calldata: calldata)
      code = <<0x60, 0, 0x35, 0x00>>
      result = EEVM.execute(code, contract: contract)
      expected = 0xFFFFFFFF00000000000000000000000000000000000000000000000000000000
      assert EEVM.stack_values(result) == [expected]
    end

    test "CALLDATALOAD beyond calldata returns 0" do
      contract = Contract.new(calldata: <<1, 2>>)
      code = <<0x60, 100, 0x35, 0x00>>
      result = EEVM.execute(code, contract: contract)
      assert EEVM.stack_values(result) == [0]
    end

    test "CALLDATACOPY copies calldata to memory" do
      calldata = <<0xAA, 0xBB, 0xCC, 0xDD>>
      contract = Contract.new(calldata: calldata)
      # PUSH1 4 (length), PUSH1 0 (data_offset), PUSH1 0 (dest_offset), CALLDATACOPY
      # PUSH1 0, MLOAD, STOP
      code = <<0x60, 4, 0x60, 0, 0x60, 0, 0x37, 0x60, 0, 0x51, 0x00>>
      result = EEVM.execute(code, contract: contract)
      # Memory word at 0: 0xAABBCCDD followed by 28 zero bytes
      expected = 0xAABBCCDD00000000000000000000000000000000000000000000000000000000
      assert EEVM.stack_values(result) == [expected]
    end

    test "CODESIZE pushes bytecode length" do
      # CODESIZE, STOP — 2 bytes of code
      code = <<0x38, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [2]
    end

    test "GASPRICE pushes tx gas price" do
      tx = Transaction.new(gasprice: 20_000_000_000)
      code = <<0x3A, 0x00>>
      result = EEVM.execute(code, tx: tx)
      assert EEVM.stack_values(result) == [20_000_000_000]
    end

    test "RETURNDATASIZE pushes 0 with no prior return" do
      code = <<0x3D, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "COINBASE pushes block producer address" do
      block = Block.new(coinbase: 0xABC)
      code = <<0x41, 0x00>>
      result = EEVM.execute(code, block: block)
      assert EEVM.stack_values(result) == [0xABC]
    end

    test "TIMESTAMP pushes block timestamp" do
      block = Block.new(timestamp: 1_700_000_000)
      code = <<0x42, 0x00>>
      result = EEVM.execute(code, block: block)
      assert EEVM.stack_values(result) == [1_700_000_000]
    end

    test "NUMBER pushes block number" do
      block = Block.new(number: 18_000_000)
      code = <<0x43, 0x00>>
      result = EEVM.execute(code, block: block)
      assert EEVM.stack_values(result) == [18_000_000]
    end

    test "PREVRANDAO pushes previous block randao" do
      block = Block.new(prevrandao: 0xDEADBEEF)
      code = <<0x44, 0x00>>
      result = EEVM.execute(code, block: block)
      assert EEVM.stack_values(result) == [0xDEADBEEF]
    end

    test "GASLIMIT pushes block gas limit" do
      block = Block.new(gaslimit: 30_000_000)
      code = <<0x45, 0x00>>
      result = EEVM.execute(code, block: block)
      assert EEVM.stack_values(result) == [30_000_000]
    end

    test "CHAINID pushes chain ID (default 1 = mainnet)" do
      code = <<0x46, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "CHAINID with custom chain ID" do
      block = Block.new(chain_id: 137)
      code = <<0x46, 0x00>>
      result = EEVM.execute(code, block: block)
      assert EEVM.stack_values(result) == [137]
    end

    test "BASEFEE pushes block base fee" do
      block = Block.new(basefee: 30_000_000_000)
      code = <<0x48, 0x00>>
      result = EEVM.execute(code, block: block)
      assert EEVM.stack_values(result) == [30_000_000_000]
    end

    test "BALANCE looks up address balance" do
      contract = Contract.new(balances: %{0xDEAD => 5_000_000})
      # PUSH2 0xDEAD, BALANCE, STOP
      code = <<0x61, 0xDE, 0xAD, 0x31, 0x00>>
      result = EEVM.execute(code, contract: contract)
      assert EEVM.stack_values(result) == [5_000_000]
    end

    test "BALANCE returns 0 for unknown address" do
      code = <<0x61, 0xDE, 0xAD, 0x31, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "SELFBALANCE pushes own contract balance" do
      contract = Contract.new(address: 0xCAFE, balances: %{0xCAFE => 999})
      code = <<0x47, 0x00>>
      result = EEVM.execute(code, contract: contract)
      assert EEVM.stack_values(result) == [999]
    end

    test "BLOCKHASH returns hash for recent block" do
      block =
        Block.new(
          number: 100,
          hashes: %{99 => 0xAAAA, 98 => 0xBBBB}
        )

      # PUSH1 99, BLOCKHASH, STOP
      code = <<0x60, 99, 0x40, 0x00>>
      result = EEVM.execute(code, block: block)
      assert EEVM.stack_values(result) == [0xAAAA]
    end

    test "BLOCKHASH returns 0 for current or future block" do
      block = Block.new(number: 100)
      # PUSH1 100, BLOCKHASH, STOP (current block → 0)
      code = <<0x60, 100, 0x40, 0x00>>
      result = EEVM.execute(code, block: block)
      assert EEVM.stack_values(result) == [0]
    end

    test "GAS pushes remaining gas after deducting for GAS opcode" do
      # GAS (0x5A), STOP
      # GAS costs 2 gas, STOP costs 0
      # So after GAS executes, gas_remaining = initial - 2
      # The value pushed should be gas AFTER the GAS opcode's cost
      code = <<0x5A, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      # GAS pushes remaining gas (1000-2=998), then STOP costs 0
      assert EEVM.stack_values(result) == [998]
      assert result.gas == 998
    end

    test "env opcodes have correct gas costs" do
      # ADDRESS costs 2 (base)
      code = <<0x30, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 2
    end

    test "BALANCE costs 2600 gas" do
      code = <<0x60, 0, 0x31, 0x00>>
      result = EEVM.execute(code, gas: 10_000)
      # PUSH1=3 + BALANCE=2600 + STOP=0 = 2603
      assert result.gas == 10_000 - 2603
    end

    test "SELFBALANCE costs 5 gas" do
      code = <<0x47, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 5
    end
  end
end
