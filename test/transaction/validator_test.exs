defmodule EEVM.Transaction.ValidatorTest do
  use ExUnit.Case, async: true

  alias EEVM.Context.{Block, Transaction}
  alias EEVM.Database.InMemory
  alias EEVM.Transaction.Validator

  @origin 0xA11CE

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

    test "returns gas limit exceeds block" do
      tx = valid_tx(gas_limit: 30_000)
      block = valid_block(gaslimit: 29_999)

      assert {:error, :gas_limit_exceeds_block} = Validator.validate(tx, db_for_sender(), block)
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

    test "returns priority fee above max fee for eip1559" do
      tx =
        valid_tx(
          type: :eip1559,
          gasprice: 0,
          max_priority_fee_per_gas: 101,
          max_fee_per_gas: 100
        )

      assert {:error, :priority_fee_above_max_fee} =
               Validator.validate(tx, db_for_sender(), valid_block(basefee: 10))
    end

    test "returns max fee below base fee for eip1559" do
      tx =
        valid_tx(
          type: :eip1559,
          gasprice: 0,
          max_priority_fee_per_gas: 10,
          max_fee_per_gas: 20
        )

      assert {:error, :max_fee_below_basefee} =
               Validator.validate(tx, db_for_sender(), valid_block(basefee: 21))
    end

    test "returns insufficient balance" do
      tx = valid_tx(gas_limit: 30_000, gasprice: 5, value: 100)
      db = db_for_sender(balance: 100_000)

      assert {:error, :insufficient_balance} = Validator.validate(tx, db, valid_block())
    end

    test "returns sender not eoa when sender has code" do
      tx = valid_tx()
      db = db_for_sender(code: <<0x60, 0x00>>)

      assert {:error, :sender_not_eoa} = Validator.validate(tx, db, valid_block())
    end

    test "returns blob tx no creation when eip4844 tx targets creation" do
      tx =
        valid_tx(
          type: :eip4844,
          to: nil,
          gas_limit: 60_000,
          gasprice: 0,
          max_fee_per_gas: 100,
          max_priority_fee_per_gas: 2,
          blob_hashes: [0x1234],
          max_fee_per_blob_gas: 10
        )

      assert {:error, :blob_tx_no_creation} =
               Validator.validate(tx, db_for_sender(balance: 10_000_000), valid_block(basefee: 1))
    end

    test "returns no blob data for eip4844 tx without blobs" do
      tx =
        valid_tx(
          type: :eip4844,
          gasprice: 0,
          max_fee_per_gas: 100,
          max_priority_fee_per_gas: 2,
          blob_hashes: [],
          max_fee_per_blob_gas: 10
        )

      assert {:error, :no_blob_data} =
               Validator.validate(tx, db_for_sender(balance: 10_000_000), valid_block(basefee: 1))
    end

    test "returns blob fee too low for eip4844 tx" do
      tx =
        valid_tx(
          type: :eip4844,
          gasprice: 0,
          max_fee_per_gas: 100,
          max_priority_fee_per_gas: 2,
          blob_hashes: [0x1234],
          max_fee_per_blob_gas: 9
        )

      assert {:error, :blob_fee_too_low} =
               Validator.validate(
                 tx,
                 db_for_sender(balance: 10_000_000),
                 valid_block(basefee: 1, blob_base_fee: 10)
               )
    end

    test "returns initcode too large for creation transaction" do
      tx = valid_tx(to: nil, data: :binary.copy(<<1>>, 49_153), gas_limit: 900_000)

      assert {:error, :initcode_too_large} =
               Validator.validate(
                 tx,
                 db_for_sender(balance: 10_000_000),
                 valid_block(gaslimit: 1_000_000)
               )
    end
  end

  defp valid_tx(overrides \\ []) do
    Transaction.new(
      [
        origin: @origin,
        nonce: 0,
        gas_limit: 30_000,
        to: 0xB0B,
        value: 0,
        data: <<>>,
        gasprice: 1,
        max_fee_per_gas: 0,
        max_priority_fee_per_gas: 0,
        access_list: [],
        blob_hashes: [],
        max_fee_per_blob_gas: 0,
        type: :legacy
      ] ++ overrides
    )
  end

  defp db_for_sender(opts \\ []) do
    balance = Keyword.get(opts, :balance, 1_000_000)
    nonce = Keyword.get(opts, :nonce, 0)
    code = Keyword.get(opts, :code, <<>>)

    InMemory.new(accounts: %{@origin => %{balance: balance, nonce: nonce, code: code}})
  end

  defp valid_block(overrides \\ []) do
    Block.new([gaslimit: 1_000_000, basefee: 0, blob_base_fee: 0] ++ overrides)
  end
end
