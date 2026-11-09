defmodule EEVM.Block.HeaderValidatorTest do
  use ExUnit.Case, async: true

  alias EEVM.Block.{Header, HeaderValidator}
  alias EEVM.HardforkConfig

  doctest HeaderValidator

  # Parent gas limit 1_024_000 gives an elasticity bound of exactly 1_000.
  @parent Header.new(number: 7, timestamp: 100, gas_limit: 1_024_000, hash: <<0xAB::256>>)

  defp child(overrides) do
    Header.new(
      [number: 8, timestamp: 112, gas_limit: 1_024_000, parent_hash: <<0xAB::256>>] ++ overrides
    )
  end

  test "accepts a valid successor" do
    assert :ok = HeaderValidator.validate(child([]), @parent)
  end

  test "rejects a parent_hash that doesn't match the parent's hash" do
    assert {:error, :unknown_parent} =
             HeaderValidator.validate(child(parent_hash: <<0xAC::256>>), @parent)
  end

  test "requires number to be exactly parent + 1" do
    assert {:error, :invalid_block_number} = HeaderValidator.validate(child(number: 9), @parent)
    assert {:error, :invalid_block_number} = HeaderValidator.validate(child(number: 7), @parent)
  end

  test "requires timestamp to be strictly greater than the parent's" do
    assert {:error, :invalid_timestamp} = HeaderValidator.validate(child(timestamp: 100), @parent)
    assert :ok = HeaderValidator.validate(child(timestamp: 101), @parent)
  end

  test "allows at most 32 bytes of extra_data" do
    assert :ok = HeaderValidator.validate(child(extra_data: <<0::256>>), @parent)

    assert {:error, :extra_data_too_big} =
             HeaderValidator.validate(child(extra_data: <<0::264>>), @parent)
  end

  test "keeps the gas limit strictly within parent_gas_limit / 1024 of the parent" do
    assert :ok = HeaderValidator.validate(child(gas_limit: 1_024_999), @parent)
    assert :ok = HeaderValidator.validate(child(gas_limit: 1_023_001), @parent)

    assert {:error, :invalid_gas_limit} =
             HeaderValidator.validate(child(gas_limit: 1_025_000), @parent)

    assert {:error, :invalid_gas_limit} =
             HeaderValidator.validate(child(gas_limit: 1_023_000), @parent)
  end

  test "rejects gas limits below the minimum or above int64 max" do
    low_parent = %{@parent | gas_limit: 5_000}

    assert {:error, :invalid_gas_limit} =
             HeaderValidator.validate(child(gas_limit: 4_999), low_parent)

    assert {:error, :gas_limit_too_big} =
             HeaderValidator.validate(child(gas_limit: Bitwise.bsl(1, 63)), @parent)
  end

  test "checks excess_blob_gas against the parent, with the EIP-7918 reserve price from Osaka" do
    # Parent at the Prague/Osaka blob target with a 1 wei blob base fee and an
    # execution base fee high enough for the reserve price to apply.
    blob_parent = %{@parent | excess_blob_gas: 0, blob_gas_used: 786_432, base_fee_per_gas: 17}
    osaka = HardforkConfig.new(:osaka)
    prague = HardforkConfig.new(:prague)

    assert :ok = HeaderValidator.validate(child(excess_blob_gas: 262_144), blob_parent, osaka)
    assert :ok = HeaderValidator.validate(child(excess_blob_gas: 0), blob_parent, prague)

    assert {:error, :invalid_excess_blob_gas} =
             HeaderValidator.validate(child(excess_blob_gas: 0), blob_parent, osaka)

    assert {:error, :invalid_excess_blob_gas} =
             HeaderValidator.validate(child(excess_blob_gas: 262_144), blob_parent, prague)
  end
end
