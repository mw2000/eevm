defmodule EEVM.Interpreter.Instructions.EnvironmentTest do
  use ExUnit.Case, async: true

  alias EEVM.BlockEnv
  alias EEVM.Context.Contract
  alias EEVM.Database.InMemory
  alias EEVM.Gas.{Dynamic, Memory, Static}
  alias EEVM.TxEnv

  describe "Environment Opcodes" do
    test "ADDRESS pushes current contract address" do
      contract = Contract.new(address: 0xCAFE)
      # ADDRESS, STOP
      code = <<0x30, 0x00>>
      result = EEVM.Interpreter.run(code, contract: contract)
      assert EEVM.stack_values(result) == [0xCAFE]
    end

    test "CALLER pushes msg.sender" do
      contract = Contract.new(caller: 0xDEAD)
      code = <<0x33, 0x00>>
      result = EEVM.Interpreter.run(code, contract: contract)
      assert EEVM.stack_values(result) == [0xDEAD]
    end

    test "ORIGIN pushes tx.origin" do
      tx = TxEnv.new(origin: 0xBEEF)
      code = <<0x32, 0x00>>
      result = EEVM.Interpreter.run(code, tx: tx)
      assert EEVM.stack_values(result) == [0xBEEF]
    end

    test "CALLVALUE pushes msg.value" do
      contract = Contract.new(callvalue: 1_000_000)
      code = <<0x34, 0x00>>
      result = EEVM.Interpreter.run(code, contract: contract)
      assert EEVM.stack_values(result) == [1_000_000]
    end

    test "CALLDATASIZE pushes length of calldata" do
      contract = Contract.new(calldata: <<1, 2, 3, 4>>)
      code = <<0x36, 0x00>>
      result = EEVM.Interpreter.run(code, contract: contract)
      assert EEVM.stack_values(result) == [4]
    end

    test "CALLDATASIZE is 0 with no calldata" do
      code = <<0x36, 0x00>>
      result = EEVM.Interpreter.run(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "CALLDATALOAD reads 32 bytes from calldata" do
      # 32 bytes of calldata, load from offset 0
      calldata = <<0::248, 42>>
      contract = Contract.new(calldata: calldata)
      # PUSH1 0, CALLDATALOAD, STOP
      code = <<0x60, 0, 0x35, 0x00>>
      result = EEVM.Interpreter.run(code, contract: contract)
      assert EEVM.stack_values(result) == [42]
    end

    test "CALLDATALOAD pads with zeros past end" do
      # 4 bytes of calldata, load from offset 0 — pads 28 zeros on right
      calldata = <<0xFF, 0xFF, 0xFF, 0xFF>>
      contract = Contract.new(calldata: calldata)
      code = <<0x60, 0, 0x35, 0x00>>
      result = EEVM.Interpreter.run(code, contract: contract)
      expected = 0xFFFFFFFF00000000000000000000000000000000000000000000000000000000
      assert EEVM.stack_values(result) == [expected]
    end

    test "CALLDATALOAD beyond calldata returns 0" do
      contract = Contract.new(calldata: <<1, 2>>)
      code = <<0x60, 100, 0x35, 0x00>>
      result = EEVM.Interpreter.run(code, contract: contract)
      assert EEVM.stack_values(result) == [0]
    end

    test "CALLDATACOPY copies calldata to memory" do
      calldata = <<0xAA, 0xBB, 0xCC, 0xDD>>
      contract = Contract.new(calldata: calldata)
      # PUSH1 4 (length), PUSH1 0 (data_offset), PUSH1 0 (dest_offset), CALLDATACOPY
      # PUSH1 0, MLOAD, STOP
      code = <<0x60, 4, 0x60, 0, 0x60, 0, 0x37, 0x60, 0, 0x51, 0x00>>
      result = EEVM.Interpreter.run(code, contract: contract)
      # Memory word at 0: 0xAABBCCDD followed by 28 zero bytes
      expected = 0xAABBCCDD00000000000000000000000000000000000000000000000000000000
      assert EEVM.stack_values(result) == [expected]
    end

    test "CALLDATACOPY gas includes static, per-word copy, and memory expansion" do
      contract = Contract.new(calldata: :binary.copy(<<0xAB>>, 40))
      # PUSH1 40 (length), PUSH1 0 (data_offset), PUSH1 0 (dest_offset), CALLDATACOPY, STOP
      code = <<0x60, 40, 0x60, 0, 0x60, 0, 0x37, 0x00>>
      result = EEVM.Interpreter.run(code, gas: 1_000, contract: contract)

      # 3 × PUSH1 (9) + CALLDATACOPY static (3) + 2 words copied (6) + 2 words of memory (6)
      assert result.frame.gas == 1_000 - 24
    end

    test "CODESIZE pushes bytecode length" do
      # CODESIZE, STOP — 2 bytes of code
      code = <<0x38, 0x00>>
      result = EEVM.Interpreter.run(code)
      assert EEVM.stack_values(result) == [2]
    end

    test "GASPRICE pushes tx gas price" do
      tx = TxEnv.new(gas_price: 20_000_000_000)
      code = <<0x3A, 0x00>>
      result = EEVM.Interpreter.run(code, tx: tx)
      assert EEVM.stack_values(result) == [20_000_000_000]
    end

    test "RETURNDATASIZE pushes 0 with no prior return" do
      code = <<0x3D, 0x00>>
      result = EEVM.Interpreter.run(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "COINBASE pushes block producer address" do
      block = BlockEnv.new(coinbase: 0xABC)
      code = <<0x41, 0x00>>
      result = EEVM.Interpreter.run(code, block: block)
      assert EEVM.stack_values(result) == [0xABC]
    end

    test "TIMESTAMP pushes block timestamp" do
      block = BlockEnv.new(timestamp: 1_700_000_000)
      code = <<0x42, 0x00>>
      result = EEVM.Interpreter.run(code, block: block)
      assert EEVM.stack_values(result) == [1_700_000_000]
    end

    test "NUMBER pushes block number" do
      block = BlockEnv.new(number: 18_000_000)
      code = <<0x43, 0x00>>
      result = EEVM.Interpreter.run(code, block: block)
      assert EEVM.stack_values(result) == [18_000_000]
    end

    test "PREVRANDAO pushes previous block randao" do
      block = BlockEnv.new(prev_randao: 0xDEADBEEF)
      code = <<0x44, 0x00>>
      result = EEVM.Interpreter.run(code, block: block)
      assert EEVM.stack_values(result) == [0xDEADBEEF]
    end

    test "GASLIMIT pushes block gas limit" do
      block = BlockEnv.new(gas_limit: 30_000_000)
      code = <<0x45, 0x00>>
      result = EEVM.Interpreter.run(code, block: block)
      assert EEVM.stack_values(result) == [30_000_000]
    end

    test "CHAINID pushes chain ID (default 1 = mainnet)" do
      code = <<0x46, 0x00>>
      result = EEVM.Interpreter.run(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "CHAINID with custom chain ID" do
      code = <<0x46, 0x00>>
      result = EEVM.Interpreter.run(code, config: EEVM.Config.new(:cancun, chain_id: 137))
      assert EEVM.stack_values(result) == [137]
    end

    test "BASEFEE pushes block base fee" do
      block = BlockEnv.new(base_fee: 30_000_000_000)
      code = <<0x48, 0x00>>
      result = EEVM.Interpreter.run(code, block: block)
      assert EEVM.stack_values(result) == [30_000_000_000]
    end

    test "BALANCE looks up address balance" do
      contract = Contract.new(balances: %{0xDEAD => 5_000_000})
      # PUSH2 0xDEAD, BALANCE, STOP
      code = <<0x61, 0xDE, 0xAD, 0x31, 0x00>>
      result = EEVM.Interpreter.run(code, contract: contract)
      assert EEVM.stack_values(result) == [5_000_000]
    end

    test "BALANCE returns 0 for unknown address" do
      code = <<0x61, 0xDE, 0xAD, 0x31, 0x00>>
      result = EEVM.Interpreter.run(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "SELFBALANCE pushes own contract balance" do
      contract = Contract.new(address: 0xCAFE, balances: %{0xCAFE => 999})
      code = <<0x47, 0x00>>
      result = EEVM.Interpreter.run(code, contract: contract)
      assert EEVM.stack_values(result) == [999]
    end

    test "BLOCKHASH returns hash for recent block" do
      block =
        BlockEnv.new(
          number: 100,
          block_hashes: %{99 => 0xAAAA, 98 => 0xBBBB}
        )

      # PUSH1 99, BLOCKHASH, STOP
      code = <<0x60, 99, 0x40, 0x00>>
      result = EEVM.Interpreter.run(code, block: block)
      assert EEVM.stack_values(result) == [0xAAAA]
    end

    test "BLOCKHASH returns 0 for current or future block" do
      block = BlockEnv.new(number: 100)
      # PUSH1 100, BLOCKHASH, STOP (current block → 0)
      code = <<0x60, 100, 0x40, 0x00>>
      result = EEVM.Interpreter.run(code, block: block)
      assert EEVM.stack_values(result) == [0]
    end

    test "GAS pushes remaining gas after deducting for GAS opcode" do
      # GAS (0x5A), STOP
      # GAS costs 2 gas, STOP costs 0
      # So after GAS executes, gas_remaining = initial - 2
      # The value pushed should be gas AFTER the GAS opcode's cost
      code = <<0x5A, 0x00>>
      result = EEVM.Interpreter.run(code, gas: 1000)
      # GAS pushes remaining gas (1000-2=998), then STOP costs 0
      assert EEVM.stack_values(result) == [998]
      assert result.frame.gas == 998
    end

    test "env opcodes have correct gas costs" do
      # ADDRESS costs 2 (base)
      code = <<0x30, 0x00>>
      result = EEVM.Interpreter.run(code, gas: 1000)
      assert result.frame.gas == 1000 - 2
    end

    test "BALANCE costs 2600 gas" do
      code = <<0x60, 0x0B, 0x31, 0x00>>
      result = EEVM.Interpreter.run(code, gas: 10_000)
      # PUSH1=3 + BALANCE=2600 + STOP=0 = 2603
      assert result.frame.gas == 10_000 - 2603
    end

    test "SELFBALANCE costs 5 gas" do
      code = <<0x47, 0x00>>
      result = EEVM.Interpreter.run(code, gas: 1000)
      assert result.frame.gas == 1000 - 5
    end
  end

  describe "CODECOPY (0x39)" do
    test "copies code bytes to memory" do
      code = <<0x60, 4, 0x60, 11, 0x60, 0, 0x39, 0x60, 0, 0x51, 0x00, 0xAA, 0xBB, 0xCC, 0xDD>>

      result = EEVM.Interpreter.run(code)

      expected = 0xAABBCCDD00000000000000000000000000000000000000000000000000000000
      assert EEVM.stack_values(result) == [expected]
    end

    test "zero-pads when reading beyond code length" do
      code = <<0x60, 4, 0x60, 13, 0x60, 0, 0x39, 0x60, 0, 0x51, 0x00, 0xAA, 0xBB, 0xCC, 0xDD>>

      result = EEVM.Interpreter.run(code)

      expected = :binary.decode_unsigned(<<0xCC, 0xDD, 0x00, 0x00, 0::224>>)
      assert EEVM.stack_values(result) == [expected]
    end

    test "zero-length copy is a no-op" do
      code = <<0x60, 0, 0x60, 200, 0x60, 10, 0x39, 0x59, 0x00>>

      result = EEVM.Interpreter.run(code)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "gas calculation includes static, copy, and memory expansion" do
      code = <<0x60, 4, 0x60, 11, 0x60, 0, 0x39, 0x60, 0, 0x51, 0x00, 0xAA, 0xBB, 0xCC, 0xDD>>
      initial_gas = 1_000

      result = EEVM.Interpreter.run(code, gas: initial_gas)

      expected_spent =
        Static.static_cost(0x60) * 4 +
          Static.static_cost(0x39) +
          Dynamic.copy_cost(4) +
          Memory.memory_expansion_cost(0, 0, 4) +
          Static.static_cost(0x51)

      assert result.frame.gas == initial_gas - expected_spent
    end
  end

  describe "RETURNDATACOPY (0x3E)" do
    test "copies return data to memory" do
      return_data = <<0xAA, 0xBB, 0xCC, 0xDD>>
      code = <<0x60, 4, 0x60, 0, 0x60, 0, 0x3E, 0x60, 0, 0x51, 0x00>>

      result = EEVM.Interpreter.run(code, return_data: return_data)

      expected = 0xAABBCCDD00000000000000000000000000000000000000000000000000000000
      assert EEVM.stack_values(result) == [expected]
    end

    test "out-of-bounds read halts exceptionally and burns all gas" do
      return_data = <<0xAA, 0xBB>>
      code = <<0x60, 2, 0x60, 1, 0x60, 0, 0x3E, 0x00>>

      result = EEVM.Interpreter.run(code, return_data: return_data)

      assert result.status == {:error, :return_data_out_of_bounds}
      assert result.frame.gas == 0
    end

    test "zero-length copy is a no-op up to the end of the return data, a halt past it" do
      return_data = <<0xAA, 0xBB>>
      # RETURNDATACOPY(dest 10, offset, size 0); MSIZE
      copy_at = fn offset -> <<0x60, 0, 0x60, offset, 0x60, 10, 0x3E, 0x59, 0x00>> end

      result = EEVM.Interpreter.run(copy_at.(2), return_data: return_data)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]

      # EIP-211 bounds-checks offset + size even when size is 0.
      result = EEVM.Interpreter.run(copy_at.(3), return_data: return_data)
      assert result.status == {:error, :return_data_out_of_bounds}
      assert result.frame.gas == 0
    end

    test "copies from middle of return data" do
      return_data = <<0x11, 0x22, 0x33, 0x44, 0x55>>
      code = <<0x60, 2, 0x60, 2, 0x60, 0, 0x3E, 0x60, 0, 0x51, 0x00>>

      result = EEVM.Interpreter.run(code, return_data: return_data)

      expected = :binary.decode_unsigned(<<0x33, 0x44, 0::240>>)
      assert EEVM.stack_values(result) == [expected]
    end

    test "gas calculation includes static, copy, and memory expansion" do
      return_data = <<0xAA, 0xBB, 0xCC, 0xDD>>
      code = <<0x60, 4, 0x60, 0, 0x60, 0, 0x3E, 0x60, 0, 0x51, 0x00>>
      initial_gas = 1_000

      result = EEVM.Interpreter.run(code, gas: initial_gas, return_data: return_data)

      expected_spent =
        Static.static_cost(0x60) * 4 +
          Static.static_cost(0x3E) +
          Dynamic.copy_cost(4) +
          Memory.memory_expansion_cost(0, 0, 4) +
          Static.static_cost(0x51)

      assert result.frame.gas == initial_gas - expected_spent
    end

    test "partial copy with destination offset" do
      return_data = <<0xAA, 0xBB>>
      code = <<0x60, 2, 0x60, 0, 0x60, 1, 0x3E, 0x60, 0, 0x51, 0x00>>

      result = EEVM.Interpreter.run(code, return_data: return_data)

      expected = :binary.decode_unsigned(<<0x00, 0xAA, 0xBB, 0::232>>)
      assert EEVM.stack_values(result) == [expected]
    end
  end

  describe "EXTCODE* opcodes" do
    test "EXTCODESIZE returns external code size" do
      world_state = InMemory.new(accounts: %{1 => %{code: <<0xAA, 0xBB, 0xCC, 0xDD>>}})
      code = <<0x60, 1, 0x3B, 0x00>>

      result = EEVM.Interpreter.run(code, db: world_state)

      assert EEVM.stack_values(result) == [4]
    end

    test "EXTCODESIZE returns 0 for non-existent account" do
      code = <<0x60, 9, 0x3B, 0x00>>
      result = EEVM.Interpreter.run(code)

      assert EEVM.stack_values(result) == [0]
    end

    test "EXTCODECOPY copies external code to memory" do
      world_state = InMemory.new(accounts: %{1 => %{code: <<0xAA, 0xBB, 0xCC, 0xDD>>}})
      code = <<0x60, 4, 0x60, 0, 0x60, 0, 0x60, 1, 0x3C, 0x60, 0, 0x51, 0x00>>

      result = EEVM.Interpreter.run(code, db: world_state)

      expected = 0xAABBCCDD00000000000000000000000000000000000000000000000000000000
      assert EEVM.stack_values(result) == [expected]
    end

    test "EXTCODECOPY zero-pads beyond code length" do
      world_state = InMemory.new(accounts: %{1 => %{code: <<0xAA, 0xBB, 0xCC, 0xDD>>}})
      code = <<0x60, 4, 0x60, 2, 0x60, 0, 0x60, 1, 0x3C, 0x60, 0, 0x51, 0x00>>

      result = EEVM.Interpreter.run(code, db: world_state)

      expected = :binary.decode_unsigned(<<0xCC, 0xDD, 0x00, 0x00, 0::224>>)
      assert EEVM.stack_values(result) == [expected]
    end

    test "EXTCODECOPY gas includes static, copy, and memory expansion" do
      world_state = InMemory.new(accounts: %{11 => %{code: <<0xAA, 0xBB, 0xCC, 0xDD>>}})
      code = <<0x60, 4, 0x60, 0, 0x60, 0, 0x60, 11, 0x3C, 0x60, 0, 0x51, 0x00>>
      initial_gas = 10_000

      result = EEVM.Interpreter.run(code, gas: initial_gas, db: world_state)

      expected_spent =
        Static.static_cost(0x60) * 5 +
          2600 +
          Static.static_cost(0x3C) +
          Dynamic.copy_cost(4) +
          Memory.memory_expansion_cost(0, 0, 4) +
          Static.static_cost(0x51)

      assert result.frame.gas == initial_gas - expected_spent
    end

    test "EXTCODEHASH returns 0 for non-existent account" do
      code = <<0x60, 2, 0x3F, 0x00>>
      result = EEVM.Interpreter.run(code)

      assert EEVM.stack_values(result) == [0]
    end

    test "EXTCODEHASH returns keccak256 of empty code for existing empty account" do
      world_state = InMemory.new(accounts: %{1 => %{code: <<>>}})
      code = <<0x60, 1, 0x3F, 0x00>>

      result = EEVM.Interpreter.run(code, db: world_state)

      <<expected::unsigned-big-256>> = ExKeccak.hash_256(<<>>)
      assert EEVM.stack_values(result) == [expected]
    end

    test "EXTCODEHASH returns keccak256 of account code" do
      world_state = InMemory.new(accounts: %{1 => %{code: <<0xAA, 0xBB, 0xCC>>}})
      code = <<0x60, 1, 0x3F, 0x00>>

      result = EEVM.Interpreter.run(code, db: world_state)

      <<expected::unsigned-big-256>> = ExKeccak.hash_256(<<0xAA, 0xBB, 0xCC>>)
      assert EEVM.stack_values(result) == [expected]
    end
  end
end
