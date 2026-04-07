defmodule EEVM.Gas.EIP2028Test do
  use ExUnit.Case, async: true

  alias EEVM.Gas.Intrinsic

  describe "EIP-2028 calldata byte pricing" do
    test "module constants are 4 gas for zero byte and 16 gas for non-zero byte" do
      assert Intrinsic.tx_data_zero_gas() == 4
      assert Intrinsic.tx_data_non_zero_gas() == 16
      assert Intrinsic.tx_calldata_floor_token_cost() == 10
    end

    test "all-zero calldata charges 4 gas per byte" do
      data = <<0x00, 0x00, 0x00, 0x00>>

      assert Intrinsic.calldata_cost(data) == 4 * byte_size(data)
    end

    test "all-non-zero calldata charges 16 gas per byte" do
      data = <<0x01, 0xFF, 0xAB, 0x7C>>

      assert Intrinsic.calldata_cost(data) == 16 * byte_size(data)
    end

    test "mixed calldata charges 4 for zero bytes and 16 for non-zero bytes" do
      data = <<0x00, 0xFF, 0x00, 0xAB>>

      assert Intrinsic.calldata_cost(data) == 40
    end

    test "empty calldata has zero intrinsic data cost" do
      assert Intrinsic.calldata_cost(<<>>) == 0
    end

    test "Prague calldata floor token pricing weights zero bytes as 1 and non-zero bytes as 4" do
      data = <<0x00, 0xFF, 0x00>>

      assert Intrinsic.calldata_floor_tokens(data) == 6
      assert Intrinsic.calldata_floor_cost(data) == 21_000 + 10 * 6
    end
  end
end
