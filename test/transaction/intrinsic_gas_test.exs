defmodule EEVM.Transaction.IntrinsicGasTest do
  use ExUnit.Case, async: true

  alias EEVM.Context.Transaction
  alias EEVM.HardforkConfig
  alias EEVM.Transaction.IntrinsicGas

  @cancun HardforkConfig.new(:cancun)

  describe "calculate/2" do
    test "plain call with empty calldata is base cost" do
      tx = Transaction.new(to: 0xCAFE, data: <<>>)
      assert IntrinsicGas.calculate(tx, @cancun) == 21_000
    end

    test "plain call with mixed calldata charges zero and non-zero bytes" do
      tx = Transaction.new(to: 0xCAFE, data: <<0x00, 0x01, 0x00, 0xFF>>)
      assert IntrinsicGas.calculate(tx, @cancun) == 21_000 + 4 + 16 + 4 + 16
    end

    test "contract creation includes create and initcode word costs" do
      tx = Transaction.new(to: nil, data: <<1, 2, 3, 4, 5>>)
      assert IntrinsicGas.calculate(tx, @cancun) == 21_000 + 32_000 + 5 * 16 + 2
    end

    test "contract creation costs 32,000 from Homestead (EIP-2), initcode words from Shanghai" do
      tx = Transaction.new(to: nil, data: :binary.copy(<<1>>, 33))

      assert IntrinsicGas.calculate(tx, HardforkConfig.new(:frontier)) == 21_000 + 33 * 68

      assert IntrinsicGas.calculate(tx, HardforkConfig.new(:homestead)) ==
               21_000 + 32_000 + 33 * 68

      assert IntrinsicGas.calculate(tx, HardforkConfig.new(:paris)) == 21_000 + 32_000 + 33 * 16

      assert IntrinsicGas.calculate(tx, HardforkConfig.new(:shanghai)) ==
               21_000 + 32_000 + 33 * 16 + 2 * 2
    end

    test "access list costs are included" do
      tx =
        Transaction.new(
          to: 0xCAFE,
          access_list: [
            {0xAA, [1, 2]},
            {0xBB, [3]}
          ]
        )

      assert IntrinsicGas.calculate(tx, @cancun) == 21_000 + 2 * 2_400 + 3 * 1_900
    end

    test "initcode word cost (EIP-3860) is charged only from Shanghai" do
      tx = Transaction.new(to: nil, data: <<1, 2, 3, 4, 5>>)

      assert IntrinsicGas.calculate(tx, HardforkConfig.new(:paris)) == 21_000 + 32_000 + 5 * 16

      assert IntrinsicGas.calculate(tx, HardforkConfig.new(:shanghai)) ==
               21_000 + 32_000 + 5 * 16 + 2
    end

    test "charges 25,000 per EIP-7702 authorization" do
      auth = %{chain_id: 1, address: 0xBB, nonce: 0, y_parity: 0, r: 1, s: 1}
      tx = Transaction.new(to: 0xCAFE, type: :eip7702, authorization_list: [auth, auth])

      assert IntrinsicGas.calculate(tx, HardforkConfig.new(:prague)) == 21_000 + 2 * 25_000
    end

    test "initcode word cost uses ceil(len/32)" do
      tx = Transaction.new(to: nil, data: :binary.copy(<<1>>, 33))

      assert IntrinsicGas.calculate(tx, @cancun) ==
               21_000 + 32_000 + 33 * 16 + 2 * 2
    end
  end

  describe "minimum_gas_limit/2" do
    test "keeps the standard intrinsic gas formula before Prague" do
      tx = Transaction.new(to: 0xCAFE, data: <<0x00>>)

      assert IntrinsicGas.minimum_gas_limit(tx, HardforkConfig.new(:cancun)) == 21_004
    end

    test "uses calldata floor pricing from Prague onward" do
      tx = Transaction.new(to: 0xCAFE, data: <<0x00, 0x01>>)

      assert IntrinsicGas.calldata_floor_gas_cost(tx, HardforkConfig.new(:prague)) == 21_050
      assert IntrinsicGas.minimum_gas_limit(tx, HardforkConfig.new(:prague)) == 21_050
    end
  end
end
