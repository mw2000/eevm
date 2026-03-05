defmodule EEVM.Opcodes.SystemTest do
  use ExUnit.Case, async: true

  describe "Executor - Return & Halt" do
    test "RETURN returns data from memory" do
      # PUSH1 0xAB, PUSH1 0, MSTORE8, PUSH1 1, PUSH1 0, RETURN
      code = <<0x60, 0xAB, 0x60, 0, 0x53, 0x60, 1, 0x60, 0, 0xF3>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert result.return_data == <<0xAB>>
    end

    test "REVERT halts with :reverted" do
      # PUSH1 0, PUSH1 0, REVERT
      code = <<0x60, 0, 0x60, 0, 0xFD>>
      result = EEVM.execute(code)
      assert result.status == :reverted
    end

    test "INVALID halts with :invalid" do
      code = <<0xFE>>
      result = EEVM.execute(code)
      assert result.status == :invalid
    end

    test "implicit STOP at end of code" do
      # PUSH1 5 (no explicit STOP)
      code = <<0x60, 5>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [5]
    end
  end
end
