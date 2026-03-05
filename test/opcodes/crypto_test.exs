defmodule EEVM.Opcodes.CryptoTest do
  use ExUnit.Case, async: true

  describe "KECCAK256" do
    test "hashes empty data" do
      # PUSH1 0 (length), PUSH1 0 (offset), KECCAK256, STOP
      code = <<0x60, 0, 0x60, 0, 0x20, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      # Keccak-256 of empty data
      expected = ExKeccak.hash_256(<<>>)
      <<expected_int::unsigned-big-256>> = expected
      assert EEVM.stack_values(result) == [expected_int]
    end

    test "hashes data stored in memory" do
      # Store 0xFF at memory[0], then hash the first byte
      # PUSH1 0xFF, PUSH1 0, MSTORE8, PUSH1 1 (length), PUSH1 0 (offset), KECCAK256, STOP
      code = <<0x60, 0xFF, 0x60, 0, 0x53, 0x60, 1, 0x60, 0, 0x20, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      expected = ExKeccak.hash_256(<<0xFF>>)
      <<expected_int::unsigned-big-256>> = expected
      assert EEVM.stack_values(result) == [expected_int]
    end

    test "static gas is 30 + dynamic 6 per word" do
      # Hash 32 bytes (1 word): PUSH1 32, PUSH1 0, KECCAK256, STOP
      # Static (charged in run_loop): 30
      # Dynamic: 6 * 1 word = 6
      # Memory expansion: 0→32 bytes = 3 gas
      # Other: PUSH1=3 + PUSH1=3 + STOP=0
      code = <<0x60, 32, 0x60, 0, 0x20, 0x00>>
      result = EEVM.execute(code, gas: 10_000)
      # Total: 3 + 3 + 30 + 6 + 3 + 0 = 45
      assert result.gas == 10_000 - 45
    end

    test "dynamic gas scales with data size" do
      # Hash 64 bytes (2 words) vs 32 bytes (1 word)
      # Extra word costs 6 more gas
      code1 = <<0x60, 32, 0x60, 0, 0x20, 0x00>>
      code2 = <<0x60, 64, 0x60, 0, 0x20, 0x00>>
      r1 = EEVM.execute(code1, gas: 100_000)
      r2 = EEVM.execute(code2, gas: 100_000)
      # r2 should use 6 more gas (1 extra word) + some memory expansion
      assert r1.gas > r2.gas
    end

    test "out of gas on large hash" do
      # Try to hash 1024 bytes with only 100 gas
      code = <<0x61, 0x04, 0x00, 0x60, 0, 0x20, 0x00>>
      result = EEVM.execute(code, gas: 100)
      assert result.status == :out_of_gas
    end

    test "disassembles as KECCAK256" do
      [{0, name, nil}] = EEVM.disassemble(<<0x20>>)
      assert name == "KECCAK256"
    end
  end
end
