defmodule EEVM.Transaction.ExecutorTest do
  use ExUnit.Case, async: true

  alias EEVM.Context.Block
  alias EEVM.Database
  alias EEVM.Database.InMemory
  alias EEVM.Transaction.{Executor, FeeMarket, Legacy, Signer}
  alias EEVM.TransactionResult

  @priv_key <<
    120,
    128,
    174,
    201,
    52,
    19,
    241,
    23,
    239,
    20,
    189,
    78,
    109,
    19,
    8,
    117,
    171,
    44,
    125,
    125,
    85,
    160,
    100,
    250,
    195,
    194,
    247,
    189,
    81,
    81,
    99,
    128
  >>

  @chain_id 1
  @coinbase 0xC0F0
  @recipient 0xB0B

  describe "execute/4 — legacy value transfer" do
    test "moves value, charges gas, bumps nonce" do
      sender = sender_address()
      starting_balance = 1_000_000

      tx = legacy_value_transfer(value: 1_000)
      db = db_with_sender(balance: starting_balance)

      assert {:ok, %TransactionResult{} = result} = run(tx, db)

      assert result.status == :success
      assert result.sender == sender
      assert result.gas_used == 21_000
      assert result.contract_address == nil
      assert result.return_data == <<>>

      # 1_000_000 - (21_000 * 1) - 1_000 = 978_000
      assert Database.get_balance(result.post_state_db, sender) == 978_000
      assert Database.get_balance(result.post_state_db, @recipient) == 1_000
      assert Database.get_nonce(result.post_state_db, sender) == 1
    end

    test "intrinsic gas too low when gas_limit < 21000" do
      tx = legacy_value_transfer(gas_limit: 20_999)

      assert {:error, :intrinsic_gas_too_low} = run(tx, db_with_sender())
    end

    test "insufficient balance for upfront cost" do
      tx = legacy_value_transfer(gas_limit: 21_000, gas_price: 1, value: 100_000_000)

      assert {:error, :insufficient_balance} = run(tx, db_with_sender(balance: 100))
    end

    test "rejects an unsigned transaction" do
      unsigned = %Legacy{
        nonce: 0,
        gas_price: 1,
        gas_limit: 21_000,
        to: <<@recipient::unsigned-big-160>>,
        value: 0,
        data: <<>>,
        v: 27,
        r: 0,
        s: 0
      }

      assert {:error, _} = run(unsigned, db_with_sender())
    end
  end

  describe "execute/4 — eip-1559 fee market" do
    test "uses min(max_fee, basefee + tip), credits coinbase the priority fee" do
      starting_balance = 10_000_000

      tx =
        sign_eip1559(%FeeMarket{
          chain_id: @chain_id,
          nonce: 0,
          max_priority_fee_per_gas: 2,
          max_fee_per_gas: 10,
          gas_limit: 21_000,
          to: <<@recipient::unsigned-big-160>>,
          value: 0,
          data: <<>>,
          access_list: [],
          y_parity: 0,
          r: 0,
          s: 0
        })

      db = db_with_sender(balance: starting_balance)
      block = simple_block(basefee: 5)

      assert {:ok, %TransactionResult{post_state_db: post_db, gas_used: 21_000}} =
               run(tx, db, block)

      # effective_price = min(10, 5 + 2) = 7
      # coinbase reward = (7 - 5) * 21_000 = 42_000
      assert Database.get_balance(post_db, @coinbase) == 42_000
      # sender pays gas_used * effective_price = 21_000 * 7 = 147_000
      assert Database.get_balance(post_db, sender_address()) == starting_balance - 147_000
    end
  end

  describe "execute/4 — CREATE" do
    test "deploys runtime code at CREATE-derived address" do
      # Initcode that returns a single STOP byte as runtime code:
      #   PUSH1 0   ; mstore8 value
      #   PUSH1 0   ; mstore8 offset
      #   MSTORE8
      #   PUSH1 1   ; return size
      #   PUSH1 0   ; return offset
      #   RETURN
      initcode = <<0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xF3>>

      tx =
        sign_legacy(
          %Legacy{
            nonce: 0,
            gas_price: 1,
            gas_limit: 200_000,
            to: <<>>,
            value: 0,
            data: initcode,
            v: 0,
            r: 0,
            s: 0
          },
          @chain_id
        )

      db = db_with_sender(balance: 10_000_000)

      assert {:ok, result} = run(tx, db)
      assert result.status == :success
      assert is_integer(result.contract_address)
      assert Database.get_code(result.post_state_db, result.contract_address) == <<0x00>>
      assert Database.get_nonce(result.post_state_db, result.contract_address) == 1
    end
  end

  describe "execute/4 — REVERT" do
    test "marks status :reverted and emits no logs" do
      # PUSH1 0 PUSH1 0 REVERT
      revert_code = <<0x60, 0x00, 0x60, 0x00, 0xFD>>

      db =
        db_with_sender(balance: 10_000_000)
        |> Database.put_code(@recipient, revert_code)

      tx = legacy_value_transfer(gas_limit: 50_000, value: 0)

      assert {:ok, result} = run(tx, db)
      assert result.status == :reverted
      assert result.logs == []
      assert result.return_data == <<>>
      # Sender's nonce was still bumped despite the revert.
      assert Database.get_nonce(result.post_state_db, sender_address()) == 1
    end
  end

  defp run(tx, db, block \\ simple_block()) do
    Executor.execute(tx, block, db, chain_id: @chain_id)
  end

  defp legacy_value_transfer(opts) do
    sign_legacy(
      %Legacy{
        nonce: Keyword.get(opts, :nonce, 0),
        gas_price: Keyword.get(opts, :gas_price, 1),
        gas_limit: Keyword.get(opts, :gas_limit, 21_000),
        to: Keyword.get(opts, :to, <<@recipient::unsigned-big-160>>),
        value: Keyword.get(opts, :value, 0),
        data: Keyword.get(opts, :data, <<>>),
        v: 0,
        r: 0,
        s: 0
      },
      @chain_id
    )
  end

  defp sign_legacy(%Legacy{} = tx, chain_id) do
    hash = Signer.signing_hash(tx, chain_id)

    {:ok, {<<r::unsigned-big-256, s::unsigned-big-256>>, recovery_id}} =
      ExSecp256k1.sign_compact(hash, @priv_key)

    %{tx | v: 35 + 2 * chain_id + recovery_id, r: r, s: s}
  end

  defp sign_eip1559(%FeeMarket{} = tx) do
    hash = Signer.signing_hash(tx, tx.chain_id)

    {:ok, {<<r::unsigned-big-256, s::unsigned-big-256>>, recovery_id}} =
      ExSecp256k1.sign_compact(hash, @priv_key)

    %{tx | y_parity: recovery_id, r: r, s: s}
  end

  defp sender_address do
    {:ok, <<4, key::binary-size(64)>>} = ExSecp256k1.create_public_key(@priv_key)
    <<_::binary-size(12), address::binary-size(20)>> = ExKeccak.hash_256(key)
    :binary.decode_unsigned(address)
  end

  defp db_with_sender(opts \\ []) do
    balance = Keyword.get(opts, :balance, 1_000_000_000)
    nonce = Keyword.get(opts, :nonce, 0)

    InMemory.new(accounts: %{sender_address() => %{balance: balance, nonce: nonce, code: <<>>}})
  end

  defp simple_block(overrides \\ []) do
    Block.new(
      [gaslimit: 30_000_000, basefee: 0, blob_base_fee: 0, coinbase: @coinbase] ++ overrides
    )
  end
end
