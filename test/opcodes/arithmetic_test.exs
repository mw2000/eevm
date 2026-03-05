defmodule EEVM.Opcodes.ArithmeticTest do
  use ExUnit.Case, async: true
  import Bitwise

  describe "Executor - Arithmetic" do
    test "PUSH1 + ADD" do
      # PUSH1 2, PUSH1 3, ADD, STOP
      code = <<0x60, 2, 0x60, 3, 0x01, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [5]
    end

    test "PUSH1 + MUL" do
      # PUSH1 7, PUSH1 6, MUL, STOP
      code = <<0x60, 7, 0x60, 6, 0x02, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [42]
    end

    test "PUSH1 + SUB" do
      # PUSH1 3, PUSH1 10, SUB, STOP  → 10 - 3 = 7
      code = <<0x60, 3, 0x60, 10, 0x03, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [7]
    end

    test "SUB underflow wraps to uint256" do
      # PUSH1 10, PUSH1 3, SUB, STOP  → 3 - 10 = -7 wraps to 2^256 - 7
      code = <<0x60, 10, 0x60, 3, 0x03, 0x00>>
      result = EEVM.execute(code)
      max = (1 <<< 256) - 1
      assert EEVM.stack_values(result) == [max - 6]
    end

    test "DIV" do
      # PUSH1 2, PUSH1 10, DIV, STOP  → 10 / 2 = 5
      code = <<0x60, 2, 0x60, 10, 0x04, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [5]
    end

    test "DIV by zero returns 0" do
      # PUSH1 0, PUSH1 10, DIV, STOP  → 10 / 0 = 0
      code = <<0x60, 0, 0x60, 10, 0x04, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "MOD" do
      # PUSH1 3, PUSH1 10, MOD, STOP  → 10 % 3 = 1
      code = <<0x60, 3, 0x60, 10, 0x06, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "EXP" do
      # PUSH1 3, PUSH1 2, EXP, STOP → 2^3 = 8
      code = <<0x60, 3, 0x60, 2, 0x0A, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [8]
    end
  end
end
