defmodule EEVM.Transaction.EnvelopeTest do
  use ExUnit.Case, async: true

  alias EEVM.Transaction
  alias EEVM.Transaction.{AccessList, Authorization, Blob, Envelope, FeeMarket, Legacy, SetCode}
  alias EEVM.Transaction.Signer

  # Self-sponsored set-code transaction from execution-spec-tests v5.4.0
  # (prague/eip7702_set_code_tx/test_self_sponsored_set_code, invalid-tx_value_0).
  @set_code_tx_bytes Base.decode16!(
                       "04F8C1018080078398968094257182563FD0AA86C431D17127F623F0E69949C38080C0" <>
                         "F85CF85A80949EACADDA90600E3AA05FFC43BF7C0B0D721C5C660101A0CB3E49FD48A0" <>
                         "6945E76F5F1E06FC98FC8B4F8EA820C7509891C8A3713D9EBA67A032A7F78AD5588799" <>
                         "858DDFFDF8304AD4CF435D0176F385417C7F14694532CC6A80A09E7711A558733E363A" <>
                         "18A5B79CB061B256E3F3661DB0E08A5EB80C583DE4F3E8A038F50EF2FC28E35DCB5B98" <>
                         "0911FCFEA096BC1624F42D03304AA54848FCCFE9FE"
                     )
  @set_code_signer Base.decode16!("257182563FD0AA86C431D17127F623F0E69949C3")

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

  describe "type 4 set-code transaction" do
    test "decodes an EEST vector, re-encodes it byte for byte, and recovers both signers" do
      assert {:ok, %SetCode{} = tx} = Envelope.decode(@set_code_tx_bytes)

      assert %SetCode{
               chain_id: 1,
               nonce: 0,
               max_fee_per_gas: 7,
               gas_limit: 10_000_000,
               to: @set_code_signer,
               access_list: [],
               authorization_list: [
                 %Authorization{chain_id: 0, nonce: 1, y_parity: 1} = auth
               ]
             } = tx

      assert auth.address == Base.decode16!("9EACADDA90600E3AA05FFC43BF7C0B0D721C5C66")
      assert Envelope.encode(tx) == @set_code_tx_bytes
      assert {:ok, @set_code_signer} = Signer.recover_sender(tx, 1)
      assert {:ok, @set_code_signer} = Signer.recover_authority(auth)
    end

    test "rejects a contract-creation target" do
      {:ok, tx} = Envelope.decode(@set_code_tx_bytes)

      assert {:error, :invalid_fields} =
               %{tx | to: <<>>} |> Envelope.encode() |> Envelope.decode()
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
