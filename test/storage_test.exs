defmodule EEVM.StorageTest do
  use ExUnit.Case, async: true

  alias EEVM.Storage

  describe "Storage (SLOAD/SSTORE)" do
    test "SSTORE then SLOAD retrieves the stored value" do
      # PUSH1 42, PUSH1 0, SSTORE, PUSH1 0, SLOAD, STOP
      code = <<0x60, 42, 0x60, 0, 0x55, 0x60, 0, 0x54, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [42]
    end

    test "SLOAD of uninitialized slot returns 0" do
      # PUSH1 99, SLOAD, STOP
      code = <<0x60, 99, 0x54, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "SSTORE overwrites previous value" do
      # Store 10 at slot 0, then store 20 at slot 0, then load slot 0
      code =
        <<0x60, 10, 0x60, 0, 0x55>> <>
          <<0x60, 20, 0x60, 0, 0x55>> <>
          <<0x60, 0, 0x54, 0x00>>

      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [20]
    end

    test "SSTORE and SLOAD with different slots" do
      # Store 111 at slot 0, store 222 at slot 1, load slot 0, load slot 1
      code =
        <<0x60, 111, 0x60, 0, 0x55>> <>
          <<0x60, 222, 0x60, 1, 0x55>> <>
          <<0x60, 0, 0x54>> <>
          <<0x60, 1, 0x54, 0x00>>

      result = EEVM.execute(code)
      # Stack: [slot1_val, slot0_val] (top first)
      assert EEVM.stack_values(result) == [222, 111]
    end

    test "SLOAD with pre-loaded storage" do
      # Pre-load slot 5 with value 9999, then SLOAD it
      storage = Storage.new(%{5 => 9999})
      code = <<0x60, 5, 0x54, 0x00>>
      result = EEVM.execute(code, storage: storage)
      assert EEVM.stack_values(result) == [9999]
    end

    test "SSTORE gas cost is 20000" do
      # PUSH1 1, PUSH1 0, SSTORE, STOP
      # Gas: PUSH1=3 + PUSH1=3 + SSTORE=20000 + STOP=0 = 20006
      code = <<0x60, 1, 0x60, 0, 0x55, 0x00>>
      result = EEVM.execute(code, gas: 100_000)
      assert result.gas == 100_000 - 20_006
    end

    test "SLOAD gas cost is 200" do
      # PUSH1 0, SLOAD, STOP
      # Gas: PUSH1=3 + SLOAD=200 + STOP=0 = 203
      code = <<0x60, 0, 0x54, 0x00>>
      result = EEVM.execute(code, gas: 1_000)
      assert result.gas == 1_000 - 203
    end

    test "SSTORE out of gas" do
      # SSTORE costs 20000 — give only 100
      code = <<0x60, 1, 0x60, 0, 0x55, 0x00>>
      result = EEVM.execute(code, gas: 100)
      assert result.status == :out_of_gas
    end

    test "storage persists across multiple SLOAD calls" do
      # Store 7 at slot 3, load slot 3 twice
      code =
        <<0x60, 7, 0x60, 3, 0x55>> <>
          <<0x60, 3, 0x54>> <>
          <<0x60, 3, 0x54, 0x00>>

      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [7, 7]
    end

    test "storage is in final machine state" do
      # Store 42 at slot 0
      code = <<0x60, 42, 0x60, 0, 0x55, 0x00>>
      result = EEVM.execute(code)
      assert Storage.load(result.storage, 0) == 42
    end
  end
end
