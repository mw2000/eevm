defmodule EEVM.Opcodes.BitwiseTest do
  use ExUnit.Case, async: true
  import Bitwise

  describe "Executor - Comparison & Bitwise" do
    test "AND, OR, XOR" do
      # PUSH1 0x0F, PUSH1 0xFF, AND, STOP → 0x0F
      code = <<0x60, 0x0F, 0x60, 0xFF, 0x16, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0x0F]
    end

    test "NOT" do
      # PUSH1 0, NOT, STOP → 2^256 - 1 (all ones)
      code = <<0x60, 0, 0x19, 0x00>>
      result = EEVM.execute(code)
      max = (1 <<< 256) - 1
      assert EEVM.stack_values(result) == [max]
    end
  end
end
