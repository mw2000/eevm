defmodule EEVM.Transaction.IntrinsicGasTest do
  use ExUnit.Case, async: true

  alias EEVM.Context.Transaction
  alias EEVM.Transaction.IntrinsicGas

  describe "calculate/1" do
    test "plain call with empty calldata is base cost" do
      tx = Transaction.new(to: 0xCAFE, data: <<>>)
      assert IntrinsicGas.calculate(tx) == 21_000
    end

    test "plain call with mixed calldata charges zero and non-zero bytes" do
      tx = Transaction.new(to: 0xCAFE, data: <<0x00, 0x01, 0x00, 0xFF>>)
      assert IntrinsicGas.calculate(tx) == 21_000 + 4 + 16 + 4 + 16
    end

    test "contract creation includes create and initcode word costs" do
      tx = Transaction.new(to: nil, data: <<1, 2, 3, 4, 5>>)
      assert IntrinsicGas.calculate(tx) == 21_000 + 32_000 + 5 * 16 + 2
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

      assert IntrinsicGas.calculate(tx) == 21_000 + 2 * 2_400 + 3 * 1_900
    end

    test "initcode word cost uses ceil(len/32)" do
      tx = Transaction.new(to: nil, data: :binary.copy(<<1>>, 33))

      assert IntrinsicGas.calculate(tx) ==
               21_000 + 32_000 + 33 * 16 + 2 * 2
    end
  end
end
