defmodule EEVM.StackTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias EEVM.Interpreter.Stack

  describe "Stack" do
    test "push and pop" do
      stack = Stack.new()
      {:ok, stack} = Stack.push(stack, 42)
      {:ok, stack} = Stack.push(stack, 99)
      {:ok, value, stack} = Stack.pop(stack)
      assert value == 99
      {:ok, value, _stack} = Stack.pop(stack)
      assert value == 42
    end

    test "underflow on empty pop" do
      assert {:error, :stack_underflow} = Stack.pop(Stack.new())
    end

    test "overflow at 1024" do
      stack =
        Enum.reduce(1..1024, Stack.new(), fn i, acc ->
          {:ok, s} = Stack.push(acc, i)
          s
        end)

      assert {:error, :stack_overflow} = Stack.push(stack, 1025)
    end

    test "values are masked to 256 bits" do
      too_big = 1 <<< 256
      {:ok, stack} = Stack.push(Stack.new(), too_big)
      {:ok, value, _} = Stack.pop(stack)
      # 2^256 wraps to 0
      assert value == 0
    end
  end
end
