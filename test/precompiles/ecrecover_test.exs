defmodule EEVM.Precompiles.ECRecoverTest do
  use ExUnit.Case, async: true

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
        |> ExKeccak.hash_256()

      input = build_input(hash, recovery_id + 27, signature)

      assert {:ok, output, @gas_cost} = ECRecover.execute(input, 10_000)
      assert byte_size(output) == 32
      assert output == <<0::96, expected_address::binary-size(20)>>
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
