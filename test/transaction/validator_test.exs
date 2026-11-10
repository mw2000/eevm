defmodule EEVM.Transaction.ValidatorTest do
  use ExUnit.Case, async: true

  alias EEVM.BlockEnv
  alias EEVM.Database.InMemory
  alias EEVM.HardforkConfig
  alias EEVM.Transaction.Validator
  alias EEVM.TxEnv

  @origin 0xA11CE
  # A blob versioned hash with the KZG version byte (0x01) EIP-4844 requires.
  @blob_hash 0x0100000000000000000000000000000000000000000000000000000000001234

  describe "validate/3" do
    test "happy path passes for valid legacy transaction" do
      tx = valid_tx(value: 10)
      db = db_for_sender(balance: 1_000_000, nonce: 0, code: <<>>)
      block = valid_block()

      assert :ok = Validator.validate(tx, db, block)
    end

    test "returns intrinsic gas too low" do
      tx = valid_tx(gas_limit: 20_999)

      assert {:error, :intrinsic_gas_too_low} =
               Validator.validate(tx, db_for_sender(), valid_block())
    end

    test "Prague enforces calldata floor gas for validity" do
      tx = valid_tx(data: <<0x00>>, gas_limit: 21_004)

      assert {:error, :intrinsic_gas_too_low} =
               Validator.validate(tx, db_for_sender(), valid_block(), HardforkConfig.new(:prague))
    end

    test "pre-Prague validation only checks standard intrinsic gas" do
      tx = valid_tx(data: <<0x00>>, gas_limit: 21_004)

      assert :ok =
               Validator.validate(tx, db_for_sender(), valid_block(), HardforkConfig.new(:cancun))
    end

    test "returns gas limit exceeds block" do
      tx = valid_tx(gas_limit: 30_000)
      block = valid_block(gas_limit: 29_999)

      assert {:error, :gas_limit_exceeds_block} = Validator.validate(tx, db_for_sender(), block)
    end

    test "Osaka caps transaction gas limit at 2^24 (EIP-7825)" do
      block = valid_block(gas_limit: 60_000_000)
      db = db_for_sender(balance: 100_000_000)
      osaka = HardforkConfig.new(:osaka)

      assert :ok = Validator.validate(valid_tx(gas_limit: 16_777_216), db, block, osaka)

      assert {:error, :gas_limit_exceeds_cap} =
               Validator.validate(valid_tx(gas_limit: 16_777_217), db, block, osaka)
    end

    test "pre-Osaka transactions above 2^24 gas are bounded only by the block" do
      block = valid_block(gas_limit: 60_000_000)
      db = db_for_sender(balance: 100_000_000)
      tx = valid_tx(gas_limit: 16_777_217)

      assert :ok = Validator.validate(tx, db, block, HardforkConfig.new(:prague))
    end

    test "returns nonce too low" do
      tx = valid_tx(nonce: 4)
      db = db_for_sender(nonce: 5)

      assert {:error, :nonce_too_low} = Validator.validate(tx, db, valid_block())
    end

    test "returns nonce too high" do
      tx = valid_tx(nonce: 6)
      db = db_for_sender(nonce: 5)

      assert {:error, :nonce_too_high} = Validator.validate(tx, db, valid_block())
    end

    # EIP-2681: a sender at nonce 2^64 - 1 can't send, since the nonce can't be
    # incremented (ethereum/tests stCreateTest/CreateTransactionHighNonce).
    test "returns nonce is max at 2^64 - 1, and accepts 2^64 - 2" do
      max = 0xFFFFFFFFFFFFFFFF

      assert {:error, :nonce_is_max} =
               Validator.validate(valid_tx(nonce: max), db_for_sender(nonce: max), valid_block())

      assert :ok =
               Validator.validate(
                 valid_tx(nonce: max - 1),
                 db_for_sender(nonce: max - 1),
                 valid_block()
               )
    end

    test "returns priority fee above max fee for eip1559" do
      tx =
        valid_tx(
          type: :eip1559,
          gas_price: 0,
          max_priority_fee_per_gas: 101,
          max_fee_per_gas: 100
        )

      assert {:error, :priority_fee_above_max_fee} =
               Validator.validate(tx, db_for_sender(), valid_block(base_fee: 10))
    end

    test "returns max fee below base fee for eip1559" do
      tx =
        valid_tx(
          type: :eip1559,
          gas_price: 0,
          max_priority_fee_per_gas: 10,
          max_fee_per_gas: 20
        )

      assert {:error, :max_fee_below_basefee} =
               Validator.validate(tx, db_for_sender(), valid_block(base_fee: 21))
    end

    test "returns insufficient balance" do
      tx = valid_tx(gas_limit: 30_000, gas_price: 5, value: 100)
      db = db_for_sender(balance: 100_000)

      assert {:error, :insufficient_balance} = Validator.validate(tx, db, valid_block())
    end

    test "returns sender not eoa when sender has code" do
      tx = valid_tx()
      db = db_for_sender(code: <<0x60, 0x00>>)

      assert {:error, :sender_not_eoa} = Validator.validate(tx, db, valid_block())
    end

    test "accepts a sender whose code is an EIP-7702 delegation designator" do
      db = db_for_sender(code: EEVM.Delegation.designator(0xBEEF))

      assert :ok = Validator.validate(valid_tx(), db, valid_block())
    end

    test "accepts each transaction type only from the fork of its EIP" do
      db = db_for_sender(balance: 1_000_000)

      for {type, first_fork, previous_fork} <-
            [
              eip2930: :berlin,
              eip1559: :london,
              eip4844: :cancun
            ]
            |> Enum.map(fn {type, fork} -> {type, fork, previous(fork)} end) do
        tx = valid_tx(type: type)

        assert {:error, :tx_type_not_supported} =
                 Validator.validate(tx, db, valid_block(), HardforkConfig.new(previous_fork))

        refute Validator.validate(tx, db, valid_block(), HardforkConfig.new(first_fork)) ==
                 {:error, :tx_type_not_supported}
      end
    end

    test "rejects set-code transactions before Prague and malformed ones from Prague" do
      auth = %{chain_id: 1, address: 0xBEEF, nonce: 0, y_parity: 0, r: 1, s: 1}
      tx = valid_tx(type: :eip7702, gas_limit: 100_000, authorization_list: [auth])
      db = db_for_sender(balance: 1_000_000)
      prague = HardforkConfig.new(:prague)

      assert :ok = Validator.validate(tx, db, valid_block(), prague)

      assert {:error, :tx_type_not_supported} =
               Validator.validate(tx, db, valid_block(), HardforkConfig.new(:cancun))

      assert {:error, :empty_authorization_list} =
               Validator.validate(%{tx | authorization_list: []}, db, valid_block(), prague)

      assert {:error, :set_code_tx_no_creation} =
               Validator.validate(%{tx | to: nil}, db, valid_block(), prague)

      # An authorization nonce must fit in 64 bits for the tx to decode at all.
      assert {:error, :invalid_authorization} =
               Validator.validate(
                 %{tx | authorization_list: [%{auth | nonce: 2 ** 64}]},
                 db,
                 valid_block(),
                 prague
               )
    end

    test "returns blob tx no creation when eip4844 tx targets creation" do
      tx =
        valid_tx(
          type: :eip4844,
          to: nil,
          gas_limit: 60_000,
          gas_price: 0,
          max_fee_per_gas: 100,
          max_priority_fee_per_gas: 2,
          blob_hashes: [@blob_hash],
          max_fee_per_blob_gas: 10
        )

      assert {:error, :blob_tx_no_creation} =
               Validator.validate(
                 tx,
                 db_for_sender(balance: 10_000_000),
                 valid_block(base_fee: 1)
               )
    end

    test "returns no blob data for eip4844 tx without blobs" do
      tx =
        valid_tx(
          type: :eip4844,
          gas_price: 0,
          max_fee_per_gas: 100,
          max_priority_fee_per_gas: 2,
          blob_hashes: [],
          max_fee_per_blob_gas: 10
        )

      assert {:error, :no_blob_data} =
               Validator.validate(
                 tx,
                 db_for_sender(balance: 10_000_000),
                 valid_block(base_fee: 1)
               )
    end

    test "returns blob fee too low for eip4844 tx" do
      tx =
        valid_tx(
          type: :eip4844,
          gas_price: 0,
          max_fee_per_gas: 100,
          max_priority_fee_per_gas: 2,
          blob_hashes: [@blob_hash],
          max_fee_per_blob_gas: 9
        )

      assert {:error, :blob_fee_too_low} =
               Validator.validate(
                 tx,
                 db_for_sender(balance: 10_000_000),
                 valid_block(base_fee: 1, blob_base_fee: 10)
               )
    end

    # EIP-4844: every versioned hash starts with VERSIONED_HASH_VERSION_KZG
    # (EEST test_invalid_blob_hash_versioning_single_tx).
    test "rejects a blob versioned hash whose version byte isn't 0x01" do
      for {version, expected} <- [
            {0x01, :ok},
            {0x00, {:error, :invalid_versioned_hash}},
            {0x02, {:error, :invalid_versioned_hash}}
          ] do
        hashes = [@blob_hash, Bitwise.bsl(version, 248) + 0x1234]
        tx = blob_tx(hashes)

        assert expected ==
                 Validator.validate(tx, db_for_sender(balance: 10_000_000), valid_block())
      end
    end

    # Cancun allows 6 blobs per block, Prague 9 (EIP-7691); Osaka caps one
    # transaction at 6 blobs (EIP-7594) though a block still holds 9.
    test "rejects more blobs than the fork allows in one transaction" do
      for {fork, max} <- [cancun: 6, prague: 9, osaka: 6] do
        config = HardforkConfig.new(fork)
        db = db_for_sender(balance: 100_000_000)

        assert :ok =
                 Validator.validate(
                   blob_tx(List.duplicate(@blob_hash, max)),
                   db,
                   valid_block(),
                   config
                 )

        assert {:error, :too_many_blobs} =
                 Validator.validate(
                   blob_tx(List.duplicate(@blob_hash, max + 1)),
                   db,
                   valid_block(),
                   config
                 )
      end
    end

    # From London a legacy or EIP-2930 gas price must cover the base fee
    # (EEST stEIP1559/lowGasPriceOldTypes).
    test "rejects a legacy or EIP-2930 gas price below the base fee from London" do
      for type <- [:legacy, :eip2930] do
        block = valid_block(base_fee: 10)

        assert :ok =
                 Validator.validate(
                   valid_tx(type: type, gas_price: 10),
                   db_for_sender(),
                   block,
                   HardforkConfig.new(:london)
                 )

        assert {:error, :max_fee_below_basefee} =
                 Validator.validate(
                   valid_tx(type: type, gas_price: 9),
                   db_for_sender(),
                   block,
                   HardforkConfig.new(:london)
                 )

        assert :ok =
                 Validator.validate(
                   valid_tx(type: type, gas_price: 9),
                   db_for_sender(),
                   block,
                   HardforkConfig.new(:berlin)
                 )
      end
    end

    test "returns initcode too large for creation transaction" do
      tx = valid_tx(to: nil, data: :binary.copy(<<1>>, 49_153), gas_limit: 900_000)

      assert {:error, :initcode_too_large} =
               Validator.validate(
                 tx,
                 db_for_sender(balance: 10_000_000),
                 valid_block(gas_limit: 1_000_000)
               )
    end
  end

  defp previous(fork) do
    ids = HardforkConfig.all_spec_ids()
    Enum.at(ids, Enum.find_index(ids, &(&1 == fork)) - 1)
  end

  defp valid_tx(overrides \\ []) do
    TxEnv.new(
      [
        origin: @origin,
        nonce: 0,
        gas_limit: 30_000,
        to: 0xB0B,
        value: 0,
        data: <<>>,
        gas_price: 1,
        max_fee_per_gas: 0,
        max_priority_fee_per_gas: 0,
        access_list: [],
        blob_hashes: [],
        max_fee_per_blob_gas: 0,
        type: :legacy
      ] ++ overrides
    )
  end

  defp blob_tx(hashes) do
    valid_tx(
      type: :eip4844,
      gas_price: 0,
      max_fee_per_gas: 10,
      max_priority_fee_per_gas: 1,
      blob_hashes: hashes,
      max_fee_per_blob_gas: 1
    )
  end

  defp db_for_sender(opts \\ []) do
    balance = Keyword.get(opts, :balance, 1_000_000)
    nonce = Keyword.get(opts, :nonce, 0)
    code = Keyword.get(opts, :code, <<>>)

    InMemory.new(accounts: %{@origin => %{balance: balance, nonce: nonce, code: code}})
  end

  defp valid_block(overrides \\ []) do
    BlockEnv.new([gas_limit: 1_000_000, base_fee: 0, blob_base_fee: 0] ++ overrides)
  end
end
