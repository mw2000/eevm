defmodule EEVM.Opcodes.StackMemoryTest do
  use ExUnit.Case, async: true

  describe "Executor - Memory" do
    test "MSTORE and MLOAD" do
      # PUSH1 0xFF, PUSH1 0, MSTORE, PUSH1 0, MLOAD, STOP
      code = <<0x60, 0xFF, 0x60, 0, 0x52, 0x60, 0, 0x51, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0xFF]
    end

    test "MSIZE" do
      # PUSH1 1, PUSH1 0, MSTORE, MSIZE, STOP
      code = <<0x60, 1, 0x60, 0, 0x52, 0x59, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [32]
    end
  end
end
