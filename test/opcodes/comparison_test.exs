defmodule EEVM.Opcodes.ComparisonTest do
  use ExUnit.Case, async: true

  describe "Executor - Comparison & Bitwise" do
    test "LT" do
      # PUSH1 5, PUSH1 3, LT, STOP  → 3 < 5 = 1 (true)
      code = <<0x60, 5, 0x60, 3, 0x10, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "GT" do
      # PUSH1 3, PUSH1 5, GT, STOP  → 5 > 3 = 1 (true)
      code = <<0x60, 3, 0x60, 5, 0x11, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "EQ true" do
      # PUSH1 42, PUSH1 42, EQ, STOP
      code = <<0x60, 42, 0x60, 42, 0x14, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "EQ false" do
      # PUSH1 1, PUSH1 2, EQ, STOP
      code = <<0x60, 1, 0x60, 2, 0x14, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "ISZERO" do
      # PUSH1 0, ISZERO, STOP  → 1
      code = <<0x60, 0, 0x15, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end
  end
end
