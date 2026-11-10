defmodule EEVM.Precompiles.ECRecoverTest do
  use ExUnit.Case, async: true

  alias EEVM.Crypto.Keccak
  alias EEVM.Precompiles.ECRecover

  @curve_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @gas_cost 3000
  @private_key <<
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

  describe "execute/2" do
    test "valid signature recovers 32-byte left-padded address" do
      hash = :crypto.hash(:sha256, "test message")
      {:ok, {signature, recovery_id}} = ExSecp256k1.sign_compact(hash, @private_key)
      {:ok, public_key} = ExSecp256k1.create_public_key(@private_key)

      <<_::binary-size(12), expected_address::binary-size(20)>> =
        public_key
        |> binary_part(1, 64)
        |> Keccak.hash_256()

      input = build_input(hash, recovery_id + 27, signature)

      assert {:ok, output, @gas_cost} = ECRecover.execute(input, 10_000)
      assert byte_size(output) == 32
      assert output == <<0::96, expected_address::binary-size(20)>>
    end

    # The precompile has no low-s rule (that is EIP-2, for transactions only).
    # Vector from ethereum/tests stCreate2/create2callPrecompiles: s > n/2,
    # recovering 0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b.
    test "high s value recovers the signer" do
      hash = Base.decode16!("18C547E4F7B0F325AD1E56F57E26C745B09A3E503D86E00E5255FF7F715D3D1C")
      r = 0x73B1693892219D736CABA55BDB67216E485557EA6B6AF75F37096C9AA6A5A75F
      s = 0xEEB940B1D03B21E36B0E47E79769F095FE2AB855BD91E3A38756B7D75A9C4549
      assert s > div(@curve_order, 2)

      input = hash <> <<28::256, r::256, s::256>>

      assert {:ok, <<0::96, 0xA94F5374FCE5EDBC8E2A8697C15331677E6EBF0B::160>>, @gas_cost} =
               ECRecover.execute(input, 10_000)
    end

    test "invalid v (not 27/28) returns empty output" do
      hash = :crypto.hash(:sha256, "test message")
      {:ok, {signature, _recovery_id}} = ExSecp256k1.sign_compact(hash, @private_key)

      input = build_input(hash, 29, signature)

      assert {:ok, <<>>, @gas_cost} = ECRecover.execute(input, 10_000)
    end

    test "invalid r value (zero) returns empty output" do
      hash = :crypto.hash(:sha256, "test message")
      signature = <<0::256, 1::256>>
      input = build_input(hash, 27, signature)

      assert {:ok, <<>>, @gas_cost} = ECRecover.execute(input, 10_000)
    end

    test "invalid s value (>= curve order) returns empty output" do
      hash = :crypto.hash(:sha256, "test message")
      r = 1
      s = @curve_order
      signature = <<r::unsigned-big-256, s::unsigned-big-256>>
      input = build_input(hash, 27, signature)

      assert {:ok, <<>>, @gas_cost} = ECRecover.execute(input, 10_000)
    end

    test "short input is zero-padded to 128 bytes and processed" do
      short_input = :binary.copy(<<0xAA>>, 96)
      assert {:ok, <<>>, @gas_cost} = ECRecover.execute(short_input, 10_000)
    end

    test "always charges flat 3000 gas" do
      hash = :crypto.hash(:sha256, "test message")
      {:ok, {signature, recovery_id}} = ExSecp256k1.sign_compact(hash, @private_key)
      input = build_input(hash, recovery_id + 27, signature)

      assert {:ok, _, @gas_cost} = ECRecover.execute(input, 10_000)
      assert {:ok, _, @gas_cost} = ECRecover.execute(<<>>, 10_000)
    end

    test "out of gas when gas_limit < 3000" do
      assert {:error, :out_of_gas} = ECRecover.execute(<<>>, 2_999)
    end

    test "exact gas_limit = 3000 succeeds" do
      assert {:ok, _, @gas_cost} = ECRecover.execute(<<>>, @gas_cost)
    end
  end

  describe "EEVM.Precompiles dispatcher" do
    test "routes address 0x01 to ECRecover" do
      assert EEVM.Precompiles.execute(0x01, <<>>, 10_000) == ECRecover.execute(<<>>, 10_000)
    end
  end

  defp build_input(hash, v, <<r::binary-size(32), s::binary-size(32)>>) do
    <<hash::binary-size(32), 0::248, v::unsigned-big-8, r::binary-size(32), s::binary-size(32)>>
  end
end
