defmodule EEVM.BlockTest do
  use ExUnit.Case, async: true

  alias EEVM.{Block, Database}
  alias EEVM.Block.{Header, Requests, Withdrawal}
  alias EEVM.Crypto.{ECDSA, Keccak, SHA256}
  alias EEVM.Database.InMemory
  alias EEVM.MPT.Trie
  alias EEVM.Transaction.{Envelope, FeeMarket, Legacy, Signer}

  doctest Block
  doctest Header

  @smoke_fixture "test/fixtures/blockchain_tests/smoke/mergeExample.json"
  @private_key <<0x46::256>>
  @recipient 0xB0B
  @coinbase 0xC0FFEE

  # EIP-7002 and EIP-7251 request contracts.
  @withdrawal_requests 0x00000961EF480EB55E80D19AD83579A64C007002
  @consolidation_requests 0x0000BBDDC7CE488642FB579F8B00F3A590007251
  # keccak256("DepositEvent(bytes,bytes,bytes,bytes,bytes)") (EIP-6110).
  @deposit_topic 0x649BBC62D0E31342AFEA4E5CD82D4049E7E1EE912FC0889AA790803BE39038C5

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
    test "build/4 defaults the timestamp to one 12-second slot after the parent's" do
      parent = %{parent() | timestamp: 1_000}
      {:ok, block, _} = Block.build(parent, [], db(), hardfork: :shanghai)

      assert block.header.timestamp == 1_012
      assert {:ok, _} = Block.execute(block, parent, db(), hardfork: :shanghai)
    end

    # The CREATE address is keccak256(rlp([sender, nonce]))[12..] (Yellow
    # Paper eq. 88); a reverted creation deploys nothing, so it has none.
    test "receipts carry the address each successful creation deployed" do
      deploy =
        signed_transfer(
          nonce: 0,
          to: nil,
          value: 0,
          gas_limit: 100_000,
          data: return_bytes(<<0xAA>>)
        )

      transfer = signed_transfer(nonce: 1)

      reverted =
        signed_transfer(
          nonce: 2,
          to: nil,
          value: 0,
          gas_limit: 100_000,
          data: <<0x5F, 0x5F, 0xFD>>
        )

      {:ok, block, built} = build([deploy, transfer, reverted])

      <<_::96, created::160>> = Keccak.hash_256(<<0xD6, 0x94, sender()::160, 0x80>>)

      assert Enum.map(built.receipts, &{&1.status, &1.contract_address}) == [
               {1, created},
               {1, nil},
               {0, nil}
             ]

      assert Database.get_code(built.db, created) == <<0xAA>>

      {:ok, result} = Block.execute(block, parent(), db())
      assert Enum.map(result.receipts, & &1.contract_address) == [created, nil, nil]
    end

    test "a built block executes to the same commitments" do
      {:ok, block, built} = build([signed_transfer()])

      assert block.header.number == 1
      assert block.header.base_fee_per_gas == 7
      assert built.gas_used == 21_000
      assert [%{tx_type: :eip1559, status: 1}] = built.receipts

      {:ok, decoded} = block |> Block.encode() |> Block.decode()
      assert {:ok, result} = Block.execute(decoded, parent(), db())
      assert result.state_root == block.header.state_root
      assert Database.get_balance(result.db, @recipient) == 1_000
      # Coinbase earns the 1 wei tip per gas; the 7 wei base fee is burned.
      assert Database.get_balance(result.db, @coinbase) == 21_000

      # The block's writes are committed once, and listed in changes.
      assert result.db.accounts == %{}
      assert result.changes.accounts[@recipient].balance == 1_000
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

    test "tracer: true returns one trace per transaction; it is nil otherwise" do
      {:ok, block, built} = build([signed_transfer(), signed_transfer(nonce: 1)])
      assert built.trace == nil

      assert {:ok, %{trace: [%EEVM.Tracer{}, %EEVM.Tracer{}]}} =
               Block.execute(block, parent(), db(), tracer: true)
    end

    test "a deprecated integer parent beacon root builds the same block as its 32-byte form" do
      {:ok, from_binary, _} = build([], parent_beacon_block_root: <<0xBEAC::256>>)
      {:ok, from_integer, _} = build([], parent_beacon_block_root: 0xBEAC)

      assert from_integer.header.parent_beacon_block_root == <<0xBEAC::256>>
      assert Block.encode(from_integer) == Block.encode(from_binary)

      assert Header.new(parent_beacon_block_root: 0xBEAC).parent_beacon_block_root ==
               <<0xBEAC::256>>
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

  describe "simulation configs" do
    test "validate/3, execute/4, and build/4 refuse a config with any simulation switch" do
      {:ok, block, _} = build([signed_transfer()])
      assert Block.validate(block, parent()) == :ok
      assert {:ok, _} = Block.execute(block, parent(), db())

      for switch <- [
            :disable_nonce_check,
            :disable_balance_check,
            :disable_base_fee,
            :disable_block_gas_limit,
            :disable_eip3607
          ] do
        config = EEVM.Config.new(:cancun, [{switch, true}])
        assert Block.validate(block, parent(), config: config) == {:error, :simulation_config}

        assert Block.execute(block, parent(), db(), config: config) ==
                 {:error, :simulation_config}

        assert build([signed_transfer()], config: config) == {:error, :simulation_config}
      end

      # The same config still relaxes a single transaction.
      config = EEVM.Config.new(:cancun, disable_nonce_check: true)

      assert {:ok, %{status: :success}} =
               EEVM.transact(signed_transfer(nonce: 5), EEVM.BlockEnv.new(), db(), config: config)
    end
  end

  describe "proof-of-work block reward" do
    # Yellow Paper section 11.3, EIP-649 (Byzantium), EIP-1234
    # (Constantinople); none from Paris (EIP-3675). An empty block pays no fees.
    for {fork, reward} <- [
          frontier: 5 * 10 ** 18,
          spurious_dragon: 5 * 10 ** 18,
          byzantium: 3 * 10 ** 18,
          constantinople: 2 * 10 ** 18,
          london: 2 * 10 ** 18,
          paris: 0
        ] do
      test "#{fork} credits the miner #{reward} wei" do
        {:ok, _block, built} = build([], hardfork: unquote(fork))
        assert Database.get_balance(built.db, @coinbase) == unquote(reward)
      end
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

  describe "EIP-7685 requests" do
    test "Prague commits to deposits, withdrawal requests, and consolidations in type order" do
      deposit = deposit_fields()
      deposit_tx = deposit_tx(deposit_event(deposit))

      db =
        requests_db(%{
          @withdrawal_requests => return_bytes(<<0xAA, 0xBB, 0xCC>>),
          @consolidation_requests => return_bytes(<<0xDD>>)
        })

      {:ok, block, built} =
        Block.build(parent(), [deposit_tx], db, timestamp: 12, hardfork: :prague)

      expected = [<<0x00>> <> Enum.join(deposit), <<0x01, 0xAA, 0xBB, 0xCC>>, <<0x02, 0xDD>>]
      assert built.requests == expected

      # EIP-7685: sha256 over the concatenated sha256 of each request.
      assert block.header.requests_hash ==
               SHA256.hash(Enum.map_join(expected, &SHA256.hash/1))

      {:ok, decoded} = block |> Block.encode() |> Block.decode()

      assert {:ok, %{requests: ^expected}} =
               Block.execute(decoded, parent(), db, hardfork: :prague)

      tampered = %{
        block
        | header: %{block.header | requests_hash: tamper(block.header.requests_hash)}
      }

      assert {:error, :invalid_requests_hash} =
               Block.execute(tampered, parent(), db, hardfork: :prague)
    end

    test "leaves out request types with no payload" do
      db = requests_db(%{@consolidation_requests => return_bytes(<<0xDD>>)})
      {:ok, block, built} = Block.build(parent(), [], db, timestamp: 12, hardfork: :prague)

      assert built.requests == [<<0x02, 0xDD>>]

      {:ok, empty, _} = Block.build(parent(), [], requests_db(), timestamp: 12, hardfork: :prague)
      assert empty.header.requests_hash == SHA256.hash(<<>>)
      assert block.header.requests_hash != empty.header.requests_hash
    end

    test "only DepositEvent logs of the deposit contract count, and they must match the EIP-6110 layout" do
      event = deposit_event(deposit_fields())
      opts = [timestamp: 12, hardfork: :prague]

      {:ok, _, built} =
        Block.build(
          parent(),
          [deposit_tx(event)],
          requests_db(),
          [deposit_contract_address: 0xDEAD] ++ opts
        )

      assert built.requests == []

      short = binary_part(event, 0, 575)
      <<_::256, bad_offset::binary>> = event

      for data <- [short, <<161::256, bad_offset::binary>>] do
        tx = deposit_tx(data)

        assert {:error, :invalid_deposit_event_layout} =
                 Block.build(parent(), [tx], requests_db(), opts)
      end
    end

    test "request contracts must have code and their calls must succeed" do
      opts = [timestamp: 12, hardfork: :prague]
      no_code = requests_db(%{@withdrawal_requests => <<>>})
      assert {:error, :system_contract_empty} = Block.build(parent(), [], no_code, opts)

      # PUSH0 PUSH0 REVERT
      reverts = requests_db(%{@consolidation_requests => <<0x5F, 0x5F, 0xFD>>})
      assert {:error, :system_contract_call_failed} = Block.build(parent(), [], reverts, opts)
    end

    test "Cancun collects no requests and has no requests_hash" do
      {:ok, block, built} = Block.build(parent(), [], db(), timestamp: 12, hardfork: :cancun)
      assert built.requests == nil
      assert block.header.requests_hash == nil
    end
  end

  # An otherwise valid empty child of `parent/0` holding one unsigned legacy
  # transaction whose calldata pads the encoded block to exactly `size` bytes.
  # validate/3 doesn't execute transactions, so the signature doesn't matter.
  defp padded_block(fork, size) do
    {:ok, block, _} = Block.build(parent(), [], requests_db(), hardfork: fork, timestamp: 12)
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
      to: @recipient,
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

  # db/0 plus the Prague request contracts: by default each just stops, so it
  # returns no requests. The deposit contract logs its calldata as a
  # DepositEvent: CALLDATACOPY it to memory, then LOG1 with the event topic.
  defp requests_db(contracts \\ %{}) do
    deposit_code = <<0x36, 0x5F, 0x5F, 0x37, 0x7F, @deposit_topic::256, 0x36, 0x5F, 0xA1, 0x00>>

    %{
      Requests.mainnet_deposit_contract() => deposit_code,
      @withdrawal_requests => <<0x00>>,
      @consolidation_requests => <<0x00>>
    }
    |> Map.merge(contracts)
    |> Enum.reduce(db(), fn {address, code}, db -> Database.put_code(db, address, code) end)
  end

  # Code that returns `bytes` (at most 32): PUSH32 the bytes, MSTORE at 0, then
  # RETURN the last byte_size(bytes) bytes of the word.
  defp return_bytes(bytes) do
    size = byte_size(bytes)

    <<0x7F, 0::size((32 - size) * 8), bytes::binary, 0x5F, 0x52, 0x60, size, 0x60, 32 - size,
      0xF3>>
  end

  defp deposit_tx(data) do
    signed_transfer(
      to: Requests.mainnet_deposit_contract(),
      data: data,
      gas_limit: 100_000
    )
  end

  # pubkey, withdrawal_credentials, amount, signature, index (EIP-6110).
  defp deposit_fields do
    [
      :binary.copy(<<1>>, 48),
      :binary.copy(<<2>>, 32),
      <<3::64>>,
      :binary.copy(<<4>>, 96),
      <<5::64>>
    ]
  end

  # The Solidity ABI encoding of DepositEvent's five `bytes` arguments: five
  # offsets, then each argument's length and its bytes right-padded to 32.
  defp deposit_event([pubkey, credentials, amount, signature, index]) do
    pad = fn bytes -> bytes <> <<0::size(rem(32 - rem(byte_size(bytes), 32), 32) * 8)>> end
    tail = fn bytes -> <<byte_size(bytes)::256>> <> pad.(bytes) end

    <<160::256, 256::256, 320::256, 384::256, 512::256>> <>
      tail.(pubkey) <> tail.(credentials) <> tail.(amount) <> tail.(signature) <> tail.(index)
  end

  defp sender do
    {:ok, {x, y}} = ECDSA.public_key(:secp256k1, @private_key)
    <<_::binary-size(12), sender::unsigned-big-160>> = Keccak.hash_256(<<x::256, y::256>>)
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
          to: @recipient,
          value: 1_000,
          data: <<>>,
          access_list: []
        },
        overrides
      )

    {:ok, {r, s, y_parity}} = ECDSA.sign(:secp256k1, Signer.signing_hash(tx, 1), @private_key)

    %{tx | y_parity: y_parity, r: r, s: s}
  end
end
