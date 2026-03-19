defmodule EEVM.Transaction.EnvelopeTest do
  use ExUnit.Case, async: true

  alias EEVM.Transaction
  alias EEVM.Transaction.{AccessList, Blob, Envelope, FeeMarket, Legacy}

  describe "encode/1 and decode/1 roundtrips" do
    test "legacy transaction" do
      tx = %Legacy{
        nonce: 1,
        gas_price: 2,
        gas_limit: 21_000,
        to: address(0x11),
        value: 3,
        data: <<0xAA, 0xBB>>,
        v: 27,
        r: 5,
        s: 6
      }

      assert {:ok, ^tx} = tx |> Envelope.encode() |> Envelope.decode()
    end

    test "type 1 access list transaction" do
      tx = %AccessList{
        chain_id: 1,
        nonce: 7,
        gas_price: 8,
        gas_limit: 50_000,
        to: <<>>,
        value: 9,
        data: <<0x12, 0x34>>,
        access_list: [
          {address(0xAA), [slot(0x01), slot(0x02)]}
        ],
        y_parity: 1,
        r: 10,
        s: 11
      }

      assert {:ok, ^tx} = tx |> Envelope.encode() |> Envelope.decode()
    end

    test "type 2 fee market transaction" do
      tx = %FeeMarket{
        chain_id: 1,
        nonce: 2,
        max_priority_fee_per_gas: 3,
        max_fee_per_gas: 100,
        gas_limit: 21_000,
        to: address(0x22),
        value: 4,
        data: <<0xDE, 0xAD>>,
        access_list: [{address(0xBB), [slot(0x99)]}],
        y_parity: 0,
        r: 12,
        s: 13
      }

      assert {:ok, ^tx} = tx |> Envelope.encode() |> Envelope.decode()
    end

    test "type 3 blob transaction" do
      tx = %Blob{
        chain_id: 1,
        nonce: 2,
        max_priority_fee_per_gas: 3,
        max_fee_per_gas: 100,
        gas_limit: 21_000,
        to: address(0x33),
        value: 4,
        data: <<0xBE, 0xEF>>,
        access_list: [{address(0xCC), [slot(0x11)]}],
        max_fee_per_blob_gas: 5,
        blob_versioned_hashes: [slot(0x77), slot(0x88)],
        y_parity: 1,
        r: 14,
        s: 15
      }

      assert {:ok, ^tx} = tx |> Envelope.encode() |> Envelope.decode()
    end
  end

  test "legacy encoding matches expected rlp bytes" do
    tx = %Legacy{
      nonce: 1,
      gas_price: 2,
      gas_limit: 3,
      to: <<>>,
      value: 4,
      data: <<>>,
      v: 27,
      r: 5,
      s: 6
    }

    assert Envelope.encode(tx) == <<0xC9, 0x01, 0x02, 0x03, 0x80, 0x04, 0x80, 0x1B, 0x05, 0x06>>
  end

  test "type 2 encoding with access list uses typed envelope format" do
    tx = %FeeMarket{
      chain_id: 1,
      nonce: 2,
      max_priority_fee_per_gas: 3,
      max_fee_per_gas: 4,
      gas_limit: 21_000,
      to: address(0x44),
      value: 5,
      data: <<0xAA>>,
      access_list: [{address(0x55), [slot(0x66)]}],
      y_parity: 1,
      r: 7,
      s: 8
    }

    expected_payload =
      ExRLP.encode([
        <<1>>,
        <<2>>,
        <<3>>,
        <<4>>,
        <<0x52, 0x08>>,
        address(0x44),
        <<5>>,
        <<0xAA>>,
        [[address(0x55), [slot(0x66)]]],
        <<1>>,
        <<7>>,
        <<8>>
      ])

    assert Envelope.encode(tx) == <<0x02>> <> expected_payload
  end

  test "decode detects legacy vs typed by first byte" do
    legacy = %Legacy{
      nonce: 0,
      gas_price: 0,
      gas_limit: 0,
      to: <<>>,
      value: 0,
      data: <<>>,
      v: 27,
      r: 1,
      s: 1
    }

    typed = %AccessList{
      chain_id: 1,
      nonce: 0,
      gas_price: 1,
      gas_limit: 21_000,
      to: <<>>,
      value: 0,
      data: <<>>,
      access_list: [],
      y_parity: 0,
      r: 1,
      s: 1
    }

    assert {:ok, %Transaction.Legacy{}} = legacy |> Envelope.encode() |> Envelope.decode()
    assert {:ok, %Transaction.AccessList{}} = typed |> Envelope.encode() |> Envelope.decode()
  end

  defp address(byte), do: :binary.copy(<<byte>>, 20)
  defp slot(byte), do: :binary.copy(<<byte>>, 32)
end
