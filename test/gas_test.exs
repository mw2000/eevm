defmodule EEVM.GasTest do
  use ExUnit.Case, async: true

  alias EEVM.Gas

  describe "Gas Metering" do
    test "gas is consumed by arithmetic opcodes" do
      # PUSH1 2, PUSH1 3, ADD, STOP
      # Gas costs: PUSH1=3, PUSH1=3, ADD=3, STOP=0 → total = 9
      code = <<0x60, 2, 0x60, 3, 0x01, 0x00>>
      result = EEVM.execute(code, gas: 1_000_000)
      assert result.status == :stopped
      assert result.gas == 1_000_000 - 9
    end

    test "out of gas halts execution" do
      # PUSH1 1, PUSH1 2, ADD, STOP — needs 9 gas, give it 5
      code = <<0x60, 1, 0x60, 2, 0x01, 0x00>>
      result = EEVM.execute(code, gas: 5)
      assert result.status == :out_of_gas
    end

    test "exact gas is sufficient" do
      # PUSH1 1, STOP — needs exactly 3 gas
      code = <<0x60, 1, 0x00>>
      result = EEVM.execute(code, gas: 3)
      assert result.status == :stopped
      assert result.gas == 0
    end

    test "one gas short causes out_of_gas" do
      # PUSH1 1, STOP — needs 3 gas, give 2
      code = <<0x60, 1, 0x00>>
      result = EEVM.execute(code, gas: 2)
      assert result.status == :out_of_gas
    end

    test "MUL costs 5 gas" do
      # PUSH1 2, PUSH1 3, MUL, STOP → 3+3+5+0 = 11
      code = <<0x60, 2, 0x60, 3, 0x02, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 11
    end

    test "DIV costs 5 gas" do
      # PUSH1 2, PUSH1 10, DIV, STOP → 3+3+5+0 = 11
      code = <<0x60, 2, 0x60, 10, 0x04, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 11
    end

    test "comparison opcodes cost 3 gas" do
      # PUSH1 1, PUSH1 2, LT, STOP → 3+3+3+0 = 9
      code = <<0x60, 1, 0x60, 2, 0x10, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 9
    end

    test "INVALID consumes all remaining gas" do
      code = <<0xFE>>
      result = EEVM.execute(code, gas: 5000)
      assert result.status == :invalid
      assert result.gas == 0
    end

    test "EXP dynamic gas charges per byte of exponent" do
      # PUSH1 0xFF, PUSH1 2, EXP, STOP
      # Static: PUSH1=3 + PUSH1=3 + EXP=10 + STOP=0
      # Dynamic: exponent 0xFF is 1 byte → 50 * 1 = 50
      # Total: 16 + 50 = 66
      code = <<0x60, 0xFF, 0x60, 2, 0x0A, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.status == :stopped
      assert result.gas == 1000 - 66
    end

    test "EXP with zero exponent has no dynamic gas" do
      # PUSH1 0, PUSH1 2, EXP, STOP
      # Static: 3+3+10+0 = 16, Dynamic: 0 bytes → 0
      code = <<0x60, 0, 0x60, 2, 0x0A, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.status == :stopped
      assert result.gas == 1000 - 16
    end

    test "EXP with 2-byte exponent charges 100 dynamic gas" do
      # PUSH2 0x0100 (=256, 2 bytes), PUSH1 2, EXP, STOP
      # Static: 3+3+10+0 = 16, Dynamic: 2 bytes → 100
      code = <<0x61, 0x01, 0x00, 0x60, 2, 0x0A, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.status == :stopped
      assert result.gas == 1000 - 116
    end

    test "memory expansion gas for MSTORE" do
      # PUSH1 0xFF, PUSH1 0, MSTORE, STOP
      # PUSH1=3 + PUSH1=3 + MSTORE=3 + mem_expansion(0→32) + STOP=0
      # Memory expansion: 0→1 word = 3*1 + 1^2/512 = 3
      code = <<0x60, 0xFF, 0x60, 0, 0x52, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.status == :stopped
      expected_gas = 3 + 3 + 3 + Gas.memory_expansion_cost_word(0, 0) + 0
      assert result.gas == 1000 - expected_gas
    end

    test "memory expansion gas grows with offset" do
      # Store at offset 1024 — expands 0→1056 bytes (33 words)
      # PUSH1 1, PUSH2 0x0400, MSTORE, STOP
      code = <<0x60, 1, 0x61, 0x04, 0x00, 0x52, 0x00>>
      result = EEVM.execute(code, gas: 100_000)
      assert result.status == :stopped
      # Memory expanded from 0 to cover offset 1024+32 = 1056 → 33 words
      mem_cost = Gas.memory_expansion_cost_word(0, 1024)
      expected_gas = 3 + 3 + 3 + mem_cost + 0
      assert result.gas == 100_000 - expected_gas
    end

    test "second memory access to same region costs no expansion" do
      # MSTORE at 0, then MLOAD at 0 — second op has no expansion
      # PUSH1 1, PUSH1 0, MSTORE, PUSH1 0, MLOAD, STOP
      code = <<0x60, 1, 0x60, 0, 0x52, 0x60, 0, 0x51, 0x00>>
      result = EEVM.execute(code, gas: 100_000)
      assert result.status == :stopped

      # First MSTORE: 3(push)+3(push)+3(mstore)+3(mem 0→32)+3(push)+3(mload)+0(mem, already 32)+0(stop)
      mem_cost1 = Gas.memory_expansion_cost_word(0, 0)
      mem_cost2 = Gas.memory_expansion_cost_word(32, 0)
      expected = 3 + 3 + 3 + mem_cost1 + 3 + 3 + mem_cost2 + 0
      assert result.gas == 100_000 - expected
    end

    test "POP costs 2 gas" do
      # PUSH1 1, POP, STOP → 3+2+0 = 5
      code = <<0x60, 1, 0x50, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 5
    end

    test "JUMP costs 8 gas" do
      # PUSH1 3, JUMP, JUMPDEST, STOP
      code = <<0x60, 3, 0x56, 0x5B, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      # PUSH1=3, JUMP=8, JUMPDEST=1, STOP=0 → 12
      assert result.gas == 1000 - 12
    end

    test "CREATE and CREATE2 static costs are 32000" do
      assert Gas.static_cost(0xF0) == 32_000
      assert Gas.static_cost(0xF5) == 32_000
    end

    test "CREATE2 hashing cost charges 6 gas per word" do
      assert Gas.create2_hash_cost(1) == 6
      assert Gas.create2_hash_cost(32) == 6
      assert Gas.create2_hash_cost(33) == 12
    end

    test "code deposit cost is 200 gas per byte" do
      assert Gas.code_deposit_cost(0) == 0
      assert Gas.code_deposit_cost(3) == 600
    end
  end
end
