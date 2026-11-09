defmodule EEVM.Transaction.SignerTest do
  use ExUnit.Case, async: true

  alias EEVM.Config
  alias EEVM.Transaction.{Envelope, FeeMarket, Legacy, Signer}

  doctest Signer

  # EIP-155 example: private key 0x4646...46 and its address.
  @eip155_key :binary.copy(<<0x46>>, 32)
  @eip155_sender "9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f"

  @secp256k1n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  describe "signing_hash/2" do
    test "legacy pre-EIP155 hash matches known vector" do
      tx = %Legacy{
        nonce: 1,
        gas_price: 2,
        gas_limit: 21_000,
        to: address(0x11),
        value: 3,
        data: <<0xAA, 0xBB>>,
        v: 27,
        r: 0,
        s: 0
      }

      assert Signer.signing_hash(tx, 1) ==
               hex!("2343a703347fccc046bb46c856667c40953a37d3bd9587b3d764bd12d273a1b5")
    end

    test "legacy post-EIP155 hash matches known vector" do
      tx = %Legacy{
        nonce: 1,
        gas_price: 2,
        gas_limit: 21_000,
        to: address(0x11),
        value: 3,
        data: <<0xAA, 0xBB>>,
        v: 37,
        r: 0,
        s: 0
      }

      assert Signer.signing_hash(tx, 1) ==
               hex!("26408a186cc892e71d2efb1ca09dba6c9a170c9019290cef4374a6f1f2f7495b")
    end

    test "type 2 hash matches known vector" do
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
        r: 0,
        s: 0
      }

      assert Signer.signing_hash(tx, 1) ==
               hex!("9b3b646b24da04572f70b09a3481b41a445745b7d6338e7bbc9dcf62657003f0")
    end
  end

  describe "recover_sender/2" do
    test "recovers sender from known signed transaction" do
      tx = %Legacy{
        nonce: 1,
        gas_price: 2,
        gas_limit: 21_000,
        to: address(0x11),
        value: 3,
        data: <<0xAA, 0xBB>>,
        v: 28,
        r: 0x2C3FF7834F2D7D13C451A2D2E657AF8D2569D0D2F0DF2E5ED94CFC3A7D3D4760,
        s: 0x2A5824F34B62A24BE3E95F0BD29F020813ADF84F378D0CC28C334000A6F02D92
      }

      assert {:ok, address} = Signer.recover_sender(tx, 1)
      assert address == hex!("1a642f0e3c3af545e7acbd38b07251b3990914f1")
    end

    test "rejects invalid signature when r is zero" do
      tx = %Legacy{
        nonce: 0,
        gas_price: 1,
        gas_limit: 21_000,
        to: <<>>,
        value: 0,
        data: <<>>,
        v: 27,
        r: 0,
        s: 1
      }

      assert {:error, :invalid_signature} = Signer.recover_sender(tx, 1)
    end

    test "rejects invalid signature when s violates low-s rule" do
      tx = %Legacy{
        nonce: 0,
        gas_price: 1,
        gas_limit: 21_000,
        to: <<>>,
        value: 0,
        data: <<>>,
        v: 27,
        r: 1,
        s: div(@secp256k1n, 2) + 1
      }

      assert {:error, :invalid_signature} = Signer.recover_sender(tx, 1)
    end
  end

  describe "sign/3" do
    test "signs a legacy transaction exactly as the EIP-155 example" do
      tx = %Legacy{
        nonce: 9,
        gas_price: 20_000_000_000,
        gas_limit: 21_000,
        to: address(0x35),
        value: 1_000_000_000_000_000_000
      }

      assert {:ok, signed} = Signer.sign(tx, @eip155_key, Config.new(:cancun, chain_id: 1))

      # The signed transaction from EIP-155, "Example".
      assert Envelope.encode(signed) ==
               hex!(
                 "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a0" <>
                   "28ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a0" <>
                   "67cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83"
               )
    end

    test "a legacy v of 27 doesn't select the pre-EIP-155 hash; v encodes the config's chain" do
      tx = %Legacy{gas_price: 1, gas_limit: 21_000, to: address(0x35), v: 27, r: 1, s: 1}

      assert {:ok, signed} = Signer.sign(tx, @eip155_key, Config.new(:cancun, chain_id: 5))
      assert signed.v in [45, 46]
      assert {:ok, sender} = Signer.recover_sender(signed, 5)
      assert Base.encode16(sender, case: :lower) == @eip155_sender
    end

    test "a typed transaction takes the config's chain id only when it has none" do
      tx = %FeeMarket{
        max_priority_fee_per_gas: 1,
        max_fee_per_gas: 2,
        gas_limit: 21_000,
        to: address(1)
      }

      config = Config.new(:cancun, chain_id: 5)

      assert {:ok, %FeeMarket{chain_id: 5} = signed} = Signer.sign(tx, @eip155_key, config)
      assert {:ok, sender} = Signer.recover_sender(signed, 5)
      assert Base.encode16(sender, case: :lower) == @eip155_sender

      assert {:ok, %FeeMarket{chain_id: 7}} =
               Signer.sign(%{tx | chain_id: 7}, @eip155_key, config)
    end

    test "rejects a zero key and one at or above the curve order" do
      tx = %FeeMarket{
        max_priority_fee_per_gas: 1,
        max_fee_per_gas: 2,
        gas_limit: 21_000,
        to: address(1)
      }

      for key <- [<<0::256>>, <<@secp256k1n::256>>] do
        assert {:error, :invalid_private_key} = Signer.sign(tx, key, Config.new())
      end
    end
  end

  defp address(byte), do: :binary.copy(<<byte>>, 20)
  defp slot(byte), do: :binary.copy(<<byte>>, 32)

  defp hex!(value) do
    Base.decode16!(value, case: :mixed)
  end
end
