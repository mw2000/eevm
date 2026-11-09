defmodule EEVM.BlockTest do
  use ExUnit.Case, async: true

  alias EEVM.{Block, Database}
  alias EEVM.Block.{Header, Withdrawal}
  alias EEVM.Database.InMemory
  alias EEVM.MPT.Trie
  alias EEVM.Transaction.{Envelope, FeeMarket, Legacy, Signer}

  doctest Block
  doctest Header

  @smoke_fixture "test/fixtures/blockchain_tests/smoke/mergeExample.json"
  @private_key <<0x46::256>>
  @recipient 0xB0B
  @coinbase 0xC0FFEE

  describe "decode/1 and encode/1" do
    test "round-trip fixture blocks byte for byte and hash headers like the fixture" do
      blocks =
        @smoke_fixture
        |> File.read!()
        |> Jason.decode!()
        |> Enum.flat_map(fn {_name, test} -> test["blocks"] end)

      assert blocks != []

      for %{"rlp" => "0x" <> hex, "blockHeader" => %{"hash" => "0x" <> hash}} <- blocks do
        rlp = Base.decode16!(hex, case: :mixed)

        assert {:ok, block} = Block.decode(rlp)
        assert Block.encode(block) == rlp
        assert block.header.hash == Base.decode16!(hash, case: :mixed)
        assert Header.compute_hash(block.header) == block.header.hash
      end
    end

    test "rejects malformed and non-canonical encodings" do
      {:ok, block, _} = build([signed_transfer()])
      rlp = Block.encode(block)

      assert {:error, :invalid_block_encoding} =
               Block.decode(binary_part(rlp, 0, byte_size(rlp) - 1))

      assert {:error, :invalid_block_encoding} = Block.decode(<<0xC0>>)

      # A gas_used of 21_000 written with a leading zero byte isn't canonical RLP.
      [header | rest] = ExRLP.decode(rlp)
      header = List.replace_at(header, 10, <<0, 0x52, 0x08>>)
      assert {:error, :invalid_block_encoding} = Block.decode(ExRLP.encode([header | rest]))
    end

    test "rejects withdrawal fields wider than 64 bits (EIP-4895)" do
      block = %Block{
        header: Header.new(base_fee_per_gas: 7, withdrawals_root: <<0::256>>),
        withdrawals: [%Withdrawal{index: 0, validator_index: 0, address: 1, amount: 2 ** 64 - 1}]
      }

      assert {:ok, _} = block |> Block.encode() |> Block.decode()

      too_big = put_in(block.withdrawals, [%Withdrawal{address: 1, amount: 2 ** 64}])
      assert {:error, :invalid_block_encoding} = too_big |> Block.encode() |> Block.decode()
    end
  end

  describe "build/4 and execute/4" do
    test "a built block executes to the same commitments" do
      {:ok, block, built} = build([signed_transfer()])

      assert block.header.number == 1
      assert block.header.base_fee_per_gas == 7
      assert built.gas_used == 21_000
      assert [%{tx_type: :eip1559, status: 1}] = built.receipts

      {:ok, decoded} = block |> Block.encode() |> Block.decode()
      assert {:ok, result} = Block.execute(decoded, parent(), db())
      assert result.state_root == block.header.state_root
      assert Database.get_balance(result.post_state_db, @recipient) == 1_000
      # Coinbase earns the 1 wei tip per gas; the 7 wei base fee is burned.
      assert Database.get_balance(result.post_state_db, @coinbase) == 21_000
    end

    test "rejects a body or result that doesn't match the header" do
      {:ok, block, _} = build([signed_transfer()])

      assert {:error, :invalid_transactions_root} =
               Block.execute(%{block | transactions: []}, parent(), db())

      for {field, reason} <- [
            gas_used: :invalid_gas_used,
            logs_bloom: :invalid_logs_bloom,
            receipts_root: :invalid_receipts_root,
            state_root: :invalid_state_root
          ] do
        header = Map.put(block.header, field, tamper(Map.fetch!(block.header, field)))
        assert {:error, ^reason} = Block.execute(%{block | header: header}, parent(), db())
      end
    end

    test "reports a rejected transaction by index" do
      assert {:error, {:tx_failed, 0, :nonce_too_high}} = build([signed_transfer(nonce: 1)])

      assert {:error, {:tx_failed, 0, :gas_allowance_exceeded}} =
               build([signed_transfer(gas_limit: 21_001)], gas_limit: 21_000)
    end

    test "runs header validation against the parent" do
      {:ok, block, _} = build([])

      assert {:error, :invalid_base_fee} =
               Block.execute(
                 %{block | header: %{block.header | base_fee_per_gas: 8}},
                 parent(),
                 db()
               )
    end
  end

  describe "EIP-7934 RLP block size limit" do
    test "Osaka accepts a block of exactly MAX_RLP_BLOCK_SIZE bytes and rejects one byte more" do
      limit = Block.max_rlp_block_size()
      assert limit == 8_388_608

      assert byte_size(Block.encode(padded_block(:osaka, limit))) == limit
      assert :ok = Block.validate(padded_block(:osaka, limit), parent(), hardfork: :osaka)

      assert {:error, :rlp_block_size_exceeded} =
               Block.validate(padded_block(:osaka, limit + 1), parent(), hardfork: :osaka)
    end

    test "Prague has no block size limit" do
      limit = Block.max_rlp_block_size()
      assert :ok = Block.validate(padded_block(:prague, limit + 1), parent(), hardfork: :prague)
    end
  end

  # An otherwise valid empty child of `parent/0` holding one unsigned legacy
  # transaction whose calldata pads the encoded block to exactly `size` bytes.
  # validate/3 doesn't execute transactions, so the signature doesn't matter.
  defp padded_block(fork, size) do
    {:ok, block, _} = Block.build(parent(), [], db(), hardfork: fork, timestamp: 12)
    with_data = fn len -> with_transaction(block, legacy_with_data(len)) end
    overhead = byte_size(Block.encode(with_data.(0)))
    padded = with_data.(size - overhead)
    # RLP length prefixes grow with the payload; correct for the difference once.
    with_data.(size - overhead - (byte_size(Block.encode(padded)) - size))
  end

  defp with_transaction(%Block{} = block, tx) do
    root = Trie.root_hash([{ExRLP.encode(0), Envelope.encode(tx)}])
    %{block | transactions: [tx], header: %{block.header | transactions_root: root}}
  end

  defp legacy_with_data(len) do
    %Legacy{
      nonce: 0,
      gas_price: 7,
      gas_limit: 21_000,
      to: <<@recipient::160>>,
      value: 0,
      data: :binary.copy(<<1>>, len),
      v: 27,
      r: 1,
      s: 1
    }
  end

  defp tamper(<<byte, rest::binary>>), do: <<Bitwise.bxor(byte, 1), rest::binary>>
  defp tamper(value) when is_integer(value), do: value + 1

  defp build(transactions, opts \\ []) do
    Block.build(parent(), transactions, db(), [timestamp: 12, coinbase: @coinbase] ++ opts)
  end

  defp parent do
    Header.new(gas_limit: 30_000_000, gas_used: 15_000_000, base_fee_per_gas: 7, hash: <<1::256>>)
  end

  defp db, do: InMemory.new(accounts: %{sender() => %{balance: 10 ** 18, nonce: 0, code: <<>>}})

  defp sender do
    {:ok, <<4, public_key::binary-size(64)>>} = ExSecp256k1.create_public_key(@private_key)
    <<_::binary-size(12), sender::unsigned-big-160>> = ExKeccak.hash_256(public_key)
    sender
  end

  defp signed_transfer(overrides \\ []) do
    tx =
      struct!(
        %FeeMarket{
          chain_id: 1,
          nonce: 0,
          max_priority_fee_per_gas: 1,
          max_fee_per_gas: 10,
          gas_limit: 21_000,
          to: <<@recipient::160>>,
          value: 1_000,
          data: <<>>,
          access_list: []
        },
        overrides
      )

    {:ok, {<<r::256, s::256>>, y_parity}} =
      ExSecp256k1.sign_compact(Signer.signing_hash(tx, 1), @private_key)

    %{tx | y_parity: y_parity, r: r, s: s}
  end
end
