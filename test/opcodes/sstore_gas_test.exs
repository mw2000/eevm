defmodule EEVM.Opcodes.SstoreGasTest do
  use ExUnit.Case, async: true

  alias EEVM.Storage

  describe "SSTORE gas schedule (EIP-2200 + EIP-3529)" do
    test "no-op SSTORE (current == new) costs 100 gas on warm slot" do
      code = <<0x60, 0x07, 0x60, 0x00, 0x55, 0x00>>

      result =
        EEVM.execute(code,
          gas: 10_000,
          storage: Storage.new(%{0 => 7}),
          accessed_storage_keys: MapSet.new([{0, 0}])
        )

      assert result.gas == 10_000 - 3 - 3 - 100
      assert result.refund == 0
    end

    test "fresh write (0 -> nonzero) on clean slot costs 20_000" do
      code = <<0x60, 0x01, 0x60, 0x00, 0x55, 0x00>>

      result =
        EEVM.execute(code,
          gas: 30_000,
          accessed_storage_keys: MapSet.new([{0, 0}])
        )

      assert result.gas == 30_000 - 3 - 3 - 20_000
      assert result.refund == 0
    end

    test "clean update (nonzero -> different nonzero) costs 2_900" do
      code = <<0x60, 0x09, 0x60, 0x00, 0x55, 0x00>>

      result =
        EEVM.execute(code,
          gas: 10_000,
          storage: Storage.new(%{0 => 7}),
          accessed_storage_keys: MapSet.new([{0, 0}])
        )

      assert result.gas == 10_000 - 3 - 3 - 2_900
      assert result.refund == 0
    end

    test "clean clear (nonzero -> 0) costs 2_900 and adds 4_800 refund" do
      code = <<0x60, 0x00, 0x60, 0x00, 0x55, 0x00>>
      initial_gas = 10_000

      result =
        EEVM.execute(code,
          gas: initial_gas,
          storage: Storage.new(%{0 => 7}),
          accessed_storage_keys: MapSet.new([{0, 0}])
        )

      # gas_used = 3 + 3 + 2900 = 2906, refund = 4800, effective = min(4800, 2906/5) = 581
      gas_used = 3 + 3 + 2_900
      effective_refund = min(4_800, div(gas_used, 5))
      assert result.gas == initial_gas - gas_used + effective_refund
      assert result.refund == 0
    end

    test "dirty slot rewrite costs 100" do
      code =
        <<0x60, 0x07, 0x60, 0x00, 0x55>> <>
          <<0x60, 0x09, 0x60, 0x00, 0x55, 0x00>>

      result =
        EEVM.execute(code,
          gas: 20_000,
          storage: Storage.new(%{0 => 5})
        )

      assert result.gas == 20_000 - (3 + 3 + 2_100 + 2_900) - (3 + 3 + 100)
      assert result.refund == 0
    end

    test "dirty slot reset to original nonzero adds 2_800 refund" do
      code = <<0x60, 0x05, 0x60, 0x00, 0x55, 0x00>>
      initial_gas = 10_000

      result =
        EEVM.execute(code,
          gas: initial_gas,
          storage: Storage.new(%{0 => 7}),
          original_storage: %{0 => 5},
          accessed_storage_keys: MapSet.new([{0, 0}])
        )

      # gas_used = 3 + 3 + 100 = 106, refund = 2800, effective = min(2800, 106/5) = 21
      gas_used = 3 + 3 + 100
      effective_refund = min(2_800, div(gas_used, 5))
      assert result.gas == initial_gas - gas_used + effective_refund
      assert result.refund == 0
    end

    test "dirty slot reset to original zero adds 19_900 refund" do
      code = <<0x60, 0x00, 0x60, 0x00, 0x55, 0x00>>
      initial_gas = 30_000

      result =
        EEVM.execute(code,
          gas: initial_gas,
          storage: Storage.new(%{0 => 7}),
          original_storage: %{0 => 0},
          accessed_storage_keys: MapSet.new([{0, 0}])
        )

      # gas_used = 3 + 3 + 100 = 106, refund = 19900, effective = min(19900, 106/5) = 21
      gas_used = 3 + 3 + 100
      effective_refund = min(19_900, div(gas_used, 5))
      assert result.gas == initial_gas - gas_used + effective_refund
      assert result.refund == 0
    end

    test "cold slot access adds 2_100 surcharge" do
      code = <<0x60, 0x07, 0x60, 0x00, 0x55, 0x00>>

      result = EEVM.execute(code, gas: 10_000, storage: Storage.new(%{0 => 7}))

      assert result.gas == 10_000 - 3 - 3 - 2_100 - 100
      assert result.refund == 0
    end

    test "warm second access has no extra surcharge" do
      code =
        <<0x60, 0x07, 0x60, 0x00, 0x55>> <>
          <<0x60, 0x07, 0x60, 0x00, 0x55, 0x00>>

      result = EEVM.execute(code, gas: 10_000, storage: Storage.new(%{0 => 7}))

      assert result.gas == 10_000 - (3 + 3 + 2_100 + 100) - (3 + 3 + 100)
      assert result.refund == 0
    end
  end
end
