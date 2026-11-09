defmodule EEVM.Block.HeaderValidatorTest do
  use ExUnit.Case, async: true

  alias EEVM.Block.{Header, HeaderValidator}
  alias EEVM.HardforkConfig

  doctest HeaderValidator

  # Parent gas limit 1_024_000 gives an elasticity bound of exactly 1_000 and
  # an EIP-1559 gas target of 512_000. Headers default to valid Cancun headers
  # (the default fork): zero base fee, post-Merge fields, and empty blob fields.
  @parent Header.new(
            number: 7,
            timestamp: 100,
            gas_limit: 1_024_000,
            gas_used: 512_000,
            hash: <<0xAB::256>>,
            blob_gas_used: 0,
            excess_blob_gas: 0
          )

  defp child(overrides) do
    Header.new(
      [
        number: 8,
        timestamp: 112,
        gas_limit: 1_024_000,
        parent_hash: <<0xAB::256>>,
        blob_gas_used: 0,
        excess_blob_gas: 0
      ] ++ overrides
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

    assert :ok =
             HeaderValidator.validate(
               child(base_fee_per_gas: 17, excess_blob_gas: 262_144),
               blob_parent,
               osaka
             )

    assert :ok =
             HeaderValidator.validate(
               child(base_fee_per_gas: 17, excess_blob_gas: 0),
               blob_parent,
               prague
             )

    assert {:error, :invalid_excess_blob_gas} =
             HeaderValidator.validate(
               child(base_fee_per_gas: 17, excess_blob_gas: 0),
               blob_parent,
               osaka
             )

    assert {:error, :invalid_excess_blob_gas} =
             HeaderValidator.validate(
               child(base_fee_per_gas: 17, excess_blob_gas: 262_144),
               blob_parent,
               prague
             )
  end

  describe "EIP-1559 base fee (from London)" do
    # Expected values follow EIP-1559 calculate_base_fee_per_gas with target
    # = 1_024_000 / 2 and a max change of 1/8 per block.
    test "rises by 1/8 after a full parent block" do
      full = %{@parent | gas_used: 1_024_000, base_fee_per_gas: 800}

      assert :ok = HeaderValidator.validate(child(base_fee_per_gas: 900), full)

      assert {:error, :invalid_base_fee} =
               HeaderValidator.validate(child(base_fee_per_gas: 899), full)

      assert {:error, :invalid_base_fee} =
               HeaderValidator.validate(child(base_fee_per_gas: 901), full)
    end

    test "falls by 1/8 after an empty parent block and holds at target" do
      empty = %{@parent | gas_used: 0, base_fee_per_gas: 800}
      at_target = %{@parent | base_fee_per_gas: 800}

      assert :ok = HeaderValidator.validate(child(base_fee_per_gas: 700), empty)

      assert {:error, :invalid_base_fee} =
               HeaderValidator.validate(child(base_fee_per_gas: 800), empty)

      assert :ok = HeaderValidator.validate(child(base_fee_per_gas: 800), at_target)
    end

    test "rises by at least 1 wei above target" do
      # 7 * 1 / 512_000 / 8 rounds to 0, so the minimum increase of 1 applies.
      busy = %{@parent | gas_used: 512_001, base_fee_per_gas: 7}

      assert :ok = HeaderValidator.validate(child(base_fee_per_gas: 8), busy)

      assert {:error, :invalid_base_fee} =
               HeaderValidator.validate(child(base_fee_per_gas: 7), busy)
    end

    test "isn't checked before London" do
      berlin = %{@parent | blob_gas_used: nil, excess_blob_gas: nil}
      header = child(base_fee_per_gas: 123, blob_gas_used: nil, excess_blob_gas: nil)

      assert :ok = HeaderValidator.validate(header, berlin, HardforkConfig.new(:berlin))
    end
  end

  describe "post-Merge fields (EIP-3675, from Paris)" do
    test "rejects non-zero difficulty or nonce and non-empty ommers" do
      assert {:error, :invalid_difficulty} =
               HeaderValidator.validate(child(difficulty: 1), @parent)

      assert {:error, :invalid_nonce} = HeaderValidator.validate(child(nonce: <<1::64>>), @parent)

      assert {:error, :invalid_ommers_hash} =
               HeaderValidator.validate(child(ommers_hash: <<1::256>>), @parent)
    end

    test "allows proof-of-work fields before Paris" do
      london_parent = %{@parent | blob_gas_used: nil, excess_blob_gas: nil}

      header =
        child(
          difficulty: 131_072,
          nonce: <<1::64>>,
          ommers_hash: <<1::256>>,
          blob_gas_used: nil,
          excess_blob_gas: nil
        )

      assert :ok = HeaderValidator.validate(header, london_parent, HardforkConfig.new(:london))
    end
  end

  describe "blob gas fields (EIP-4844)" do
    test "are required from Cancun and rejected before" do
      shanghai = HardforkConfig.new(:shanghai)
      pre_cancun_parent = %{@parent | blob_gas_used: nil, excess_blob_gas: nil}

      assert {:error, :missing_blob_fields} =
               HeaderValidator.validate(child(blob_gas_used: nil), @parent)

      assert {:error, :missing_blob_fields} =
               HeaderValidator.validate(child(excess_blob_gas: nil), @parent)

      assert {:error, :unexpected_blob_fields} =
               HeaderValidator.validate(child([]), pre_cancun_parent, shanghai)

      header = child(blob_gas_used: nil, excess_blob_gas: nil)
      assert :ok = HeaderValidator.validate(header, pre_cancun_parent, shanghai)
    end

    test "blob_gas_used is a whole number of blobs within the fork's maximum" do
      prague = HardforkConfig.new(:prague)

      assert {:error, :invalid_blob_gas_used} =
               HeaderValidator.validate(child(blob_gas_used: 131_071), @parent)

      # Cancun allows 6 blobs per block; Prague (EIP-7691) allows 9.
      assert :ok = HeaderValidator.validate(child(blob_gas_used: 6 * 131_072), @parent)

      assert {:error, :invalid_blob_gas_used} =
               HeaderValidator.validate(child(blob_gas_used: 7 * 131_072), @parent)

      assert :ok = HeaderValidator.validate(child(blob_gas_used: 9 * 131_072), @parent, prague)

      assert {:error, :invalid_blob_gas_used} =
               HeaderValidator.validate(child(blob_gas_used: 10 * 131_072), @parent, prague)
    end
  end
end
