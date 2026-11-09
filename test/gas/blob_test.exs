defmodule EEVM.Gas.BlobTest do
  use ExUnit.Case, async: true

  alias EEVM.Gas.Blob
  alias EEVM.HardforkConfig

  doctest Blob

  # Prague/Osaka schedule: target 6 blobs (786_432 blob gas), max 9.
  @target_blob_gas 786_432

  # With excess 0 the blob base fee is 1 wei, so the EIP-7918 reserve price
  # (8_192 * base_fee_per_gas > 131_072 * 1) kicks in once base_fee_per_gas > 16.
  defp parent(base_fee),
    do: %{excess_blob_gas: 0, blob_gas_used: @target_blob_gas, base_fee_per_gas: base_fee}

  describe "calc_excess_blob_gas/2" do
    test "Osaka stops subtracting the target once execution cost exceeds blob cost" do
      osaka = HardforkConfig.new(:osaka)

      assert Blob.calc_excess_blob_gas(parent(16), osaka) == 0
      assert Blob.calc_excess_blob_gas(parent(17), osaka) == div(@target_blob_gas * 3, 9)
    end

    test "Prague subtracts the target regardless of the execution base fee" do
      assert Blob.calc_excess_blob_gas(parent(17), HardforkConfig.new(:prague)) == 0
    end

    test "Osaka returns zero below target even when the reserve price applies" do
      below_target = %{parent(1_000_000_000) | blob_gas_used: @target_blob_gas - 1}

      assert Blob.calc_excess_blob_gas(below_target, HardforkConfig.new(:osaka)) == 0
    end

    test "Cancun uses the EIP-4844 target of 3 blobs" do
      cancun_parent = %{excess_blob_gas: 0, blob_gas_used: 6 * 131_072, base_fee_per_gas: 7}

      assert Blob.calc_excess_blob_gas(cancun_parent, HardforkConfig.new(:cancun)) ==
               3 * 131_072
    end
  end

  test "base_fee_per_blob_gas uses the fork's update fraction" do
    assert Blob.base_fee_per_blob_gas(10_000_000, HardforkConfig.new(:cancun)) == 19
    assert Blob.base_fee_per_blob_gas(10_000_000, HardforkConfig.new(:prague)) == 7
  end
end
