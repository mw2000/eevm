defmodule EEVM.Interpreter.Instructions.TransientStorageTest do
  use ExUnit.Case, async: true

  alias EEVM.Gas.Static

  describe "TLOAD and TSTORE (EIP-1153)" do
    test "TLOAD returns 0 for unset key" do
      # PUSH1 0 (key), TLOAD, STOP
      code = <<0x60, 0x00, 0x5C, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "TSTORE then TLOAD reads back value" do
      # PUSH1 0xFF (value), PUSH1 0x01 (key), TSTORE, PUSH1 0x01 (key), TLOAD, STOP
      code = <<0x60, 0xFF, 0x60, 0x01, 0x5D, 0x60, 0x01, 0x5C, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0xFF]
    end

    test "TSTORE overwrites previous value" do
      # Store 0xAA at key 1, then store 0xBB at key 1, then load key 1
      code =
        IO.iodata_to_binary([
          # TSTORE(1, 0xAA)
          <<0x60, 0xAA, 0x60, 0x01, 0x5D>>,
          # TSTORE(1, 0xBB)
          <<0x60, 0xBB, 0x60, 0x01, 0x5D>>,
          # TLOAD(1)
          <<0x60, 0x01, 0x5C>>,
          # STOP
          <<0x00>>
        ])

      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0xBB]
    end

    test "different keys are independent" do
      # Store 0xAA at key 1, store 0xBB at key 2, load key 1, load key 2
      code =
        IO.iodata_to_binary([
          # TSTORE(1, 0xAA)
          <<0x60, 0xAA, 0x60, 0x01, 0x5D>>,
          # TSTORE(2, 0xBB)
          <<0x60, 0xBB, 0x60, 0x02, 0x5D>>,
          # TLOAD(1) -> 0xAA
          <<0x60, 0x01, 0x5C>>,
          # TLOAD(2) -> 0xBB
          <<0x60, 0x02, 0x5C>>,
          <<0x00>>
        ])

      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0xBB, 0xAA]
    end

    test "TSTORE reverts in static context" do
      code = <<0x60, 0xFF, 0x60, 0x01, 0x5D, 0x00>>
      result = EEVM.execute(code, is_static: true)
      assert result.status == :reverted
    end

    test "TLOAD works in static context" do
      code = <<0x60, 0x00, 0x5C, 0x00>>
      result = EEVM.execute(code, is_static: true)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "TLOAD costs 100 gas (warm access)" do
      code = <<0x60, 0x00, 0x5C, 0x00>>
      result = EEVM.execute(code, gas: 10_000)
      expected_cost = Static.static_cost(0x60) + Static.static_cost(0x5C)
      assert result.gas == 10_000 - expected_cost
    end

    test "TSTORE costs 100 gas (warm access)" do
      code = <<0x60, 0xFF, 0x60, 0x01, 0x5D, 0x00>>
      result = EEVM.execute(code, gas: 10_000)
      expected_cost = Static.static_cost(0x60) * 2 + Static.static_cost(0x5D)
      assert result.gas == 10_000 - expected_cost
    end

    test "transient storage does not affect persistent storage" do
      # TSTORE to key 1, then SLOAD key 1 should be 0
      code =
        IO.iodata_to_binary([
          # TSTORE(1, 0xFF)
          <<0x60, 0xFF, 0x60, 0x01, 0x5D>>,
          # SLOAD(1) -> 0
          <<0x60, 0x01, 0x54>>,
          <<0x00>>
        ])

      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end
  end
end
