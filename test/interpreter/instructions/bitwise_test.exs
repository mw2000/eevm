defmodule EEVM.Interpreter.Instructions.BitwiseTest do
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

  describe "CLZ (0x1E, EIP-7939)" do
    # PUSH32 x, CLZ, STOP
    defp clz(x, opts \\ [hardfork: :osaka]), do: EEVM.execute(<<0x7F, x::256, 0x1E, 0x00>>, opts)

    test "returns 256 for zero" do
      assert EEVM.stack_values(clz(0)) == [256]
    end

    test "returns 255 for one" do
      assert EEVM.stack_values(clz(1)) == [255]
    end

    test "returns 0 when the top bit is set" do
      assert EEVM.stack_values(clz(1 <<< 255)) == [0]
      assert EEVM.stack_values(clz((1 <<< 256) - 1)) == [0]
    end

    test "counts zeros above the highest set bit, ignoring lower bits" do
      assert EEVM.stack_values(clz(1 <<< 254)) == [1]
      assert EEVM.stack_values(clz((1 <<< 255) - 1)) == [1]
      assert EEVM.stack_values(clz((1 <<< 200) + 0xFF)) == [55]
      assert EEVM.stack_values(clz(0xFF)) == [248]
      assert EEVM.stack_values(clz(0x100)) == [247]
    end

    test "costs 5 gas" do
      # PUSH32 (3) + CLZ (5) + STOP (0)
      result = clz(1, hardfork: :osaka, gas: 100)
      assert result.status == :stopped
      assert result.frame.gas == 100 - 8
    end

    test "stack underflow on empty stack" do
      result = EEVM.execute(<<0x1E, 0x00>>, hardfork: :osaka)
      assert result.status == {:error, :stack_underflow}
    end

    test "is invalid before Osaka" do
      assert clz(1, hardfork: :prague).status == :invalid
      assert clz(1, hardfork: :cancun).status == :invalid
    end
  end
end
