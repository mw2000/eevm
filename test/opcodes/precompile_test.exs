defmodule EEVM.Opcodes.PrecompileTest do
  use ExUnit.Case, async: true

  alias EEVM.WorldState

  describe "Precompile routing (EIP-34)" do
    test "CALL to unimplemented precompile pushes 0 (failure)" do
      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x0A, 0x61, 0xFF,
          0xFF, 0xF1, 0x00>>

      result = EEVM.execute(code, gas: 1_000_000)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "STATICCALL to unimplemented precompile pushes 0" do
      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x0A, 0x61, 0xFF, 0xFF, 0xFA,
          0x00>>

      result = EEVM.execute(code, gas: 1_000_000)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "CALL to non-precompile address still works normally" do
      child_code = <<0x60, 0x2A, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xF3>>

      world_state =
        WorldState.new(%{
          0 => %{balance: 10},
          0x100 => %{balance: 0, code: child_code}
        })

      code =
        <<0x60, 0x01, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x61, 0x01, 0x00, 0x61,
          0xFF, 0xFF, 0xF1, 0x00>>

      result = EEVM.execute(code, world_state: world_state, gas: 1_000_000)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [1]
      assert result.return_data == <<0x2A>>
    end

    test "precompile detection for addresses 0x01 through 0x0A" do
      alias EEVM.Precompiles

      for addr <- 0x01..0x0A do
        assert Precompiles.is_precompile?(addr) == true
      end

      assert Precompiles.is_precompile?(0x00) == false
      assert Precompiles.is_precompile?(0x0B) == false
      assert Precompiles.is_precompile?(0xFF) == false
    end

    test "DELEGATECALL to unimplemented precompile pushes 0" do
      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x0A, 0x61, 0xFF, 0xFF, 0xF4,
          0x00>>

      result = EEVM.execute(code, gas: 1_000_000)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "CALL to identity precompile (0x04) succeeds and pushes 1" do
      # PUSH1 0 (retSize), PUSH1 0 (retOff), PUSH1 0 (argsSize), PUSH1 0 (argsOff),
      # PUSH1 0 (value), PUSH1 0x04 (address), PUSH2 0xFFFF (gas), CALL, STOP
      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x04, 0x61, 0xFF,
          0xFF, 0xF1, 0x00>>

      result = EEVM.execute(code, gas: 1_000_000)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [1]
    end
  end
end
