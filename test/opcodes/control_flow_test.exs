defmodule EEVM.Opcodes.ControlFlowTest do
  use ExUnit.Case, async: true

  describe "Executor - Stack Operations" do
    test "POP" do
      # PUSH1 1, PUSH1 2, POP, STOP  → [1]
      code = <<0x60, 1, 0x60, 2, 0x50, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "DUP1" do
      # PUSH1 42, DUP1, STOP  → [42, 42]
      code = <<0x60, 42, 0x80, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [42, 42]
    end

    test "DUP2" do
      # PUSH1 1, PUSH1 2, DUP2, STOP  → [1, 2, 1]
      code = <<0x60, 1, 0x60, 2, 0x81, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1, 2, 1]
    end

    test "SWAP1" do
      # PUSH1 1, PUSH1 2, SWAP1, STOP  → [1, 2]
      code = <<0x60, 1, 0x60, 2, 0x90, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1, 2]
    end

    test "PUSH2 (multi-byte push)" do
      # PUSH2 0x0100, STOP  → 256
      code = <<0x61, 0x01, 0x00, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [256]
    end
  end

  describe "Executor - Control Flow" do
    test "JUMP to JUMPDEST" do
      # PUSH1 4, JUMP, INVALID, JUMPDEST, PUSH1 42, STOP
      # PC:  0     2    3       4         5       7
      code = <<0x60, 4, 0x56, 0xFE, 0x5B, 0x60, 42, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [42]
    end

    test "JUMPI taken" do
      # PUSH1 1, PUSH1 6, JUMPI, INVALID, INVALID, INVALID, JUMPDEST, PUSH1 99, STOP
      code = <<0x60, 1, 0x60, 6, 0x57, 0xFE, 0x5B, 0x60, 99, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [99]
    end

    test "JUMPI not taken" do
      # PUSH1 0, PUSH1 8, JUMPI, PUSH1 42, STOP
      code = <<0x60, 0, 0x60, 8, 0x57, 0x60, 42, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [42]
    end
  end

  describe "PUSH0 (EIP-3855)" do
    test "pushes 0 onto the stack" do
      # PUSH0, STOP
      code = <<0x5F, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "PUSH0 costs 2 gas (base)" do
      code = <<0x5F, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 2
    end

    test "PUSH0 + PUSH0 + ADD = 0" do
      # PUSH0, PUSH0, ADD, STOP
      code = <<0x5F, 0x5F, 0x01, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "PUSH0 is cheaper than PUSH1 0" do
      # PUSH0 costs 2, PUSH1 costs 3
      push0_code = <<0x5F, 0x00>>
      push1_code = <<0x60, 0, 0x00>>
      r0 = EEVM.execute(push0_code, gas: 1000)
      r1 = EEVM.execute(push1_code, gas: 1000)
      assert r0.gas > r1.gas
    end

    test "disassembles as PUSH0" do
      [{0, name, nil}] = EEVM.disassemble(<<0x5F>>)
      assert name == "PUSH0"
    end
  end
end
