defmodule EEVM.GasTest do
  use ExUnit.Case, async: true
  import EEVM.TestSupport.MachineHelpers

  alias EEVM.Gas.{Dynamic, Memory, Static}

  doctest Dynamic
  doctest Static

  describe "Gas Metering" do
    test "gas is consumed by arithmetic opcodes" do
      # PUSH1 2, PUSH1 3, ADD, STOP
      # Gas costs: PUSH1=3, PUSH1=3, ADD=3, STOP=0 → total = 9
      code = <<0x60, 2, 0x60, 3, 0x01, 0x00>>
      result = run_code(code, gas: 1_000_000)
      assert result.status == :stopped
      assert result.frame.gas == 1_000_000 - 9
    end

    test "out of gas halts execution" do
      # PUSH1 1, PUSH1 2, ADD, STOP — needs 9 gas, give it 5
      code = <<0x60, 1, 0x60, 2, 0x01, 0x00>>
      result = run_code(code, gas: 5)
      assert result.status == :out_of_gas
    end

    test "exact gas is sufficient" do
      # PUSH1 1, STOP — needs exactly 3 gas
      code = <<0x60, 1, 0x00>>
      result = run_code(code, gas: 3)
      assert result.status == :stopped
      assert result.frame.gas == 0
    end

    test "one gas short causes out_of_gas" do
      # PUSH1 1, STOP — needs 3 gas, give 2
      code = <<0x60, 1, 0x00>>
      result = run_code(code, gas: 2)
      assert result.status == :out_of_gas
    end

    test "MUL costs 5 gas" do
      # PUSH1 2, PUSH1 3, MUL, STOP → 3+3+5+0 = 11
      code = <<0x60, 2, 0x60, 3, 0x02, 0x00>>
      result = run_code(code, gas: 1000)
      assert result.frame.gas == 1000 - 11
    end

    test "DIV costs 5 gas" do
      # PUSH1 2, PUSH1 10, DIV, STOP → 3+3+5+0 = 11
      code = <<0x60, 2, 0x60, 10, 0x04, 0x00>>
      result = run_code(code, gas: 1000)
      assert result.frame.gas == 1000 - 11
    end

    test "comparison opcodes cost 3 gas" do
      # PUSH1 1, PUSH1 2, LT, STOP → 3+3+3+0 = 9
      code = <<0x60, 1, 0x60, 2, 0x10, 0x00>>
      result = run_code(code, gas: 1000)
      assert result.frame.gas == 1000 - 9
    end

    test "INVALID consumes all remaining gas" do
      code = <<0xFE>>
      result = run_code(code, gas: 5000)
      assert result.status == :invalid
      assert result.frame.gas == 0
    end

    test "EXP dynamic gas charges per byte of exponent" do
      # PUSH1 0xFF, PUSH1 2, EXP, STOP
      # Static: PUSH1=3 + PUSH1=3 + EXP=10 + STOP=0
      # Dynamic: exponent 0xFF is 1 byte → 50 * 1 = 50
      # Total: 16 + 50 = 66
      code = <<0x60, 0xFF, 0x60, 2, 0x0A, 0x00>>
      result = run_code(code, gas: 1000)
      assert result.status == :stopped
      assert result.frame.gas == 1000 - 66
    end

    test "EXP with zero exponent has no dynamic gas" do
      # PUSH1 0, PUSH1 2, EXP, STOP
      # Static: 3+3+10+0 = 16, Dynamic: 0 bytes → 0
      code = <<0x60, 0, 0x60, 2, 0x0A, 0x00>>
      result = run_code(code, gas: 1000)
      assert result.status == :stopped
      assert result.frame.gas == 1000 - 16
    end

    test "EXP with 2-byte exponent charges 100 dynamic gas" do
      # PUSH2 0x0100 (=256, 2 bytes), PUSH1 2, EXP, STOP
      # Static: 3+3+10+0 = 16, Dynamic: 2 bytes → 100
      code = <<0x61, 0x01, 0x00, 0x60, 2, 0x0A, 0x00>>
      result = run_code(code, gas: 1000)
      assert result.status == :stopped
      assert result.frame.gas == 1000 - 116
    end

    test "memory expansion gas for MSTORE" do
      # PUSH1 0xFF, PUSH1 0, MSTORE, STOP
      # PUSH1=3 + PUSH1=3 + MSTORE=3 + mem_expansion(0→32) + STOP=0
      # Memory expansion: 0→1 word = 3*1 + 1^2/512 = 3
      code = <<0x60, 0xFF, 0x60, 0, 0x52, 0x00>>
      result = run_code(code, gas: 1000)
      assert result.status == :stopped
      expected_gas = 3 + 3 + 3 + Memory.memory_expansion_cost_word(0, 0) + 0
      assert result.frame.gas == 1000 - expected_gas
    end

    test "memory expansion gas grows with offset" do
      # Store at offset 1024 — expands 0→1056 bytes (33 words)
      # PUSH1 1, PUSH2 0x0400, MSTORE, STOP
      code = <<0x60, 1, 0x61, 0x04, 0x00, 0x52, 0x00>>
      result = run_code(code, gas: 100_000)
      assert result.status == :stopped
      # Memory expanded from 0 to cover offset 1024+32 = 1056 → 33 words
      mem_cost = Memory.memory_expansion_cost_word(0, 1024)
      expected_gas = 3 + 3 + 3 + mem_cost + 0
      assert result.frame.gas == 100_000 - expected_gas
    end

    test "second memory access to same region costs no expansion" do
      # MSTORE at 0, then MLOAD at 0 — second op has no expansion
      # PUSH1 1, PUSH1 0, MSTORE, PUSH1 0, MLOAD, STOP
      code = <<0x60, 1, 0x60, 0, 0x52, 0x60, 0, 0x51, 0x00>>
      result = run_code(code, gas: 100_000)
      assert result.status == :stopped

      # First MSTORE: 3(push)+3(push)+3(mstore)+3(mem 0→32)+3(push)+3(mload)+0(mem, already 32)+0(stop)
      mem_cost1 = Memory.memory_expansion_cost_word(0, 0)
      mem_cost2 = Memory.memory_expansion_cost_word(32, 0)
      expected = 3 + 3 + 3 + mem_cost1 + 3 + 3 + mem_cost2 + 0
      assert result.frame.gas == 100_000 - expected
    end

    test "POP costs 2 gas" do
      # PUSH1 1, POP, STOP → 3+2+0 = 5
      code = <<0x60, 1, 0x50, 0x00>>
      result = run_code(code, gas: 1000)
      assert result.frame.gas == 1000 - 5
    end

    test "JUMP costs 8 gas" do
      # PUSH1 3, JUMP, JUMPDEST, STOP
      code = <<0x60, 3, 0x56, 0x5B, 0x00>>
      result = run_code(code, gas: 1000)
      # PUSH1=3, JUMP=8, JUMPDEST=1, STOP=0 → 12
      assert result.frame.gas == 1000 - 12
    end

    test "CREATE and CREATE2 static costs are 32000" do
      assert Static.static_cost(0xF0) == 32_000
      assert Static.static_cost(0xF5) == 32_000
    end

    test "CREATE2 hashing cost charges 6 gas per word" do
      assert Dynamic.create2_hash_cost(1) == 6
      assert Dynamic.create2_hash_cost(32) == 6
      assert Dynamic.create2_hash_cost(33) == 12
    end

    test "code deposit cost is 200 gas per byte" do
      assert Dynamic.code_deposit_cost(0) == 0
      assert Dynamic.code_deposit_cost(3) == 600
    end

    test "CALL static gas is warm access cost" do
      assert Static.static_cost(0xF1) == 100
    end

    test "CALL forwarded gas follows EIP-150 63/64 rule" do
      tangerine_whistle = EEVM.HardforkConfig.new(:tangerine_whistle)
      assert Dynamic.call_forwarded_gas(6400, 6400, tangerine_whistle) == 6300
      assert Dynamic.call_forwarded_gas(6400, 1000, tangerine_whistle) == 1000
    end

    test "before EIP-150 CALL forwards the full request" do
      homestead = EEVM.HardforkConfig.new(:homestead)
      assert Dynamic.call_forwarded_gas(6400, 6400, homestead) == 6400
      assert Dynamic.call_forwarded_gas(6400, 9000, homestead) == 9000
    end

    test "before EIP-150 a CALL requesting more gas than is left runs out of gas" do
      # CALL(gas: GAS, to: 0x42, value 0, no memory), STOP
      code = <<0x60, 0, 0x60, 0, 0x60, 0, 0x60, 0, 0x60, 0, 0x60, 0x42, 0x5A, 0xF1, 0x00>>

      assert run_code(code, gas: 100_000, hardfork: :homestead).status == :out_of_gas
      assert run_code(code, gas: 100_000, hardfork: :tangerine_whistle).status == :stopped
    end

    test "EXP costs 10 gas per exponent byte before Spurious Dragon (EIP-160), 50 after" do
      exponent = 0x0100
      assert Dynamic.exp_dynamic_cost(exponent, EEVM.HardforkConfig.new(:tangerine_whistle)) == 20
      assert Dynamic.exp_dynamic_cost(exponent, EEVM.HardforkConfig.new(:spurious_dragon)) == 100
    end

    test "CALL new-account charge: missing target before EIP-161, value to an empty one after" do
      homestead = EEVM.HardforkConfig.new(:homestead)
      spurious_dragon = EEVM.HardforkConfig.new(:spurious_dragon)

      # {exists?, empty?, value}
      assert Dynamic.call_new_account_cost(false, true, 0, homestead) == 25_000
      assert Dynamic.call_new_account_cost(true, true, 1, homestead) == 0
      assert Dynamic.call_new_account_cost(false, true, 0, spurious_dragon) == 0
      assert Dynamic.call_new_account_cost(true, true, 1, spurious_dragon) == 25_000
      assert Dynamic.call_new_account_cost(true, false, 1, spurious_dragon) == 0
    end

    test "CALL stipend applies only when value is non-zero" do
      assert Dynamic.call_stipend(0) == 0
      assert Dynamic.call_stipend(1) == 2300
    end
  end
end
