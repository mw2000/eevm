defmodule EEVM.ReceiptTest do
  use ExUnit.Case, async: true

  alias EEVM.{Bloom, Receipt}

  describe "new/0" do
    test "returns a successful, empty receipt" do
      receipt = Receipt.new()

      assert receipt.status == 1
      assert receipt.cumulative_gas_used == 0
      assert receipt.logs == []
      assert receipt.logs_bloom == Bloom.empty()
    end
  end

  describe "new/1" do
    test "applies overrides while keeping defaults for unspecified fields" do
      receipt = Receipt.new(status: 0, cumulative_gas_used: 21_000)

      assert receipt.status == 0
      assert receipt.cumulative_gas_used == 21_000
      assert receipt.logs == []
      assert receipt.logs_bloom == Bloom.empty()
    end

    test "derives logs_bloom from :logs when only logs are supplied" do
      logs = [
        %{address: 0xAAAA, topics: [0x1111, 0x2222], data: <<0xDE, 0xAD>>},
        %{address: 0xBBBB, topics: [0x3333], data: <<>>}
      ]

      receipt = Receipt.new(logs: logs)

      assert receipt.logs == logs
      assert receipt.logs_bloom == Bloom.from_logs(logs)
      refute receipt.logs_bloom == Bloom.empty()
    end

    test "lets callers inject a logs_bloom directly when re-hydrating" do
      precomputed = Bloom.add(Bloom.empty(), <<0xCAFE::unsigned-big-160>>)

      receipt = Receipt.new(logs_bloom: precomputed)

      assert receipt.logs == []
      assert receipt.logs_bloom == precomputed
    end
  end

  describe "encode/2 — legacy form" do
    test "produces the canonical RLP list of [status, cumulative_gas, bloom, logs]" do
      receipt = Receipt.new(status: 1, cumulative_gas_used: 21_000)

      expected =
        ExRLP.encode([
          # status = 1 → minimal big-endian byte
          <<1>>,
          # 21_000 → 0x5208
          <<0x52, 0x08>>,
          Bloom.empty(),
          []
        ])

      assert Receipt.encode(receipt) == expected
      # RLP list prefix for a list with this much content lives in 0xC0..0xFF.
      assert :binary.first(Receipt.encode(receipt)) >= 0xC0
    end

    test "encodes a reverted (status=0) receipt with empty status byte" do
      receipt = Receipt.new(status: 0, cumulative_gas_used: 50_000)

      decoded = ExRLP.decode(Receipt.encode(receipt))

      # RLP integer 0 round-trips through ExRLP as the empty binary.
      assert [<<>>, <<0xC3, 0x50>>, bloom, []] = decoded
      assert byte_size(bloom) == 256
    end

    test "encodes log entries as [address(20B), [topics(32B)...], data]" do
      log = %{address: 0xCAFE, topics: [0x01, 0x02], data: <<0xAA, 0xBB>>}
      receipt = Receipt.new(status: 1, cumulative_gas_used: 100, logs: [log])

      [_status, _cumulative, _bloom, [encoded_log]] =
        ExRLP.decode(Receipt.encode(receipt))

      assert encoded_log == [
               <<0xCAFE::unsigned-big-160>>,
               [<<1::unsigned-big-256>>, <<2::unsigned-big-256>>],
               <<0xAA, 0xBB>>
             ]
    end
  end

  describe "encode/2 — typed (EIP-2718)" do
    test "tx_type: :legacy emits no prefix byte" do
      receipt = Receipt.new(status: 1)

      assert Receipt.encode(receipt, tx_type: :legacy) == Receipt.encode(receipt)
    end

    test "tx_type: :eip2930 prepends 0x01" do
      receipt = Receipt.new(status: 1)
      encoded = Receipt.encode(receipt, tx_type: :eip2930)

      assert <<0x01, rest::binary>> = encoded
      assert rest == Receipt.encode(receipt)
    end

    test "tx_type: :eip1559 prepends 0x02" do
      receipt = Receipt.new(status: 1)
      encoded = Receipt.encode(receipt, tx_type: :eip1559)

      assert <<0x02, rest::binary>> = encoded
      assert rest == Receipt.encode(receipt)
    end

    test "tx_type: :eip4844 prepends 0x03" do
      receipt = Receipt.new(status: 1)
      encoded = Receipt.encode(receipt, tx_type: :eip4844)

      assert <<0x03, rest::binary>> = encoded
      assert rest == Receipt.encode(receipt)
    end

    test "accepts a raw integer tx type byte" do
      receipt = Receipt.new(status: 1)

      assert <<0x02, _::binary>> = Receipt.encode(receipt, tx_type: 0x02)
    end
  end

  describe "logs_bloom integration" do
    test "bloom contains the address and indexed topics of every log" do
      logs = [
        %{address: 0x1111, topics: [0xAAA], data: <<>>},
        %{address: 0x2222, topics: [0xBBB, 0xCCC], data: <<0x01>>}
      ]

      receipt = Receipt.new(logs: logs)

      assert Bloom.contains?(receipt.logs_bloom, <<0x1111::unsigned-big-160>>)
      assert Bloom.contains?(receipt.logs_bloom, <<0x2222::unsigned-big-160>>)
      assert Bloom.contains?(receipt.logs_bloom, <<0xAAA::unsigned-big-256>>)
      assert Bloom.contains?(receipt.logs_bloom, <<0xBBB::unsigned-big-256>>)
      assert Bloom.contains?(receipt.logs_bloom, <<0xCCC::unsigned-big-256>>)
    end
  end
end
