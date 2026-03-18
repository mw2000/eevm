defmodule EEVM.Precompiles.KZGPointEvalTest do
  use ExUnit.Case, async: true

  alias EEVM.Precompiles.KZGPointEval

  @gas_cost 50_000
  @field_elements_per_blob 4_096
  @bls_modulus 52_435_875_175_126_190_479_447_740_508_185_965_837_690_552_500_527_637_822_603_658_699_938_581_184_513

  describe "execute/2" do
    test "invalid input length returns invalid_input" do
      assert {:error, :invalid_input} =
               KZGPointEval.execute(:binary.copy(<<0x00>>, 191), @gas_cost)

      assert {:error, :invalid_input} =
               KZGPointEval.execute(:binary.copy(<<0x00>>, 193), @gas_cost)
    end

    test "out of gas when gas_limit < 50_000" do
      assert {:error, :out_of_gas} = KZGPointEval.execute(valid_input(), @gas_cost - 1)
    end

    test "exact gas_limit = 50_000 succeeds" do
      assert {:ok, output, @gas_cost} = KZGPointEval.execute(valid_input(), @gas_cost)
      assert byte_size(output) == 64
    end

    test "versioned hash mismatch returns invalid_versioned_hash" do
      bad_hash = :binary.copy(<<0xFF>>, 32)
      input = build_input(versioned_hash: bad_hash)

      assert {:error, :invalid_versioned_hash} = KZGPointEval.execute(input, @gas_cost)
    end

    test "z >= BLS_MODULUS is rejected" do
      input = build_input(z: <<@bls_modulus::unsigned-big-256>>)
      assert {:error, :invalid_field_element} = KZGPointEval.execute(input, @gas_cost)
    end

    test "y >= BLS_MODULUS is rejected" do
      input = build_input(y: <<@bls_modulus::unsigned-big-256>>)
      assert {:error, :invalid_field_element} = KZGPointEval.execute(input, @gas_cost)
    end

    test "input parsing respects field offsets" do
      commitment = :binary.copy(<<0xAB>>, 48)
      proof = :binary.copy(<<0xCD>>, 48)
      z = <<123_456::unsigned-big-256>>
      y = <<654_321::unsigned-big-256>>
      versioned_hash = compute_versioned_hash(commitment)

      input =
        <<versioned_hash::binary, z::binary, y::binary, commitment::binary, proof::binary>>

      assert {:ok, _output, @gas_cost} = KZGPointEval.execute(input, @gas_cost)
    end

    test "output format is two 32-byte constants" do
      assert {:ok, output, @gas_cost} = KZGPointEval.execute(valid_input(), @gas_cost)

      <<field_elements_per_blob::unsigned-big-256, bls_modulus::unsigned-big-256>> = output

      assert field_elements_per_blob == @field_elements_per_blob
      assert bls_modulus == @bls_modulus
    end
  end

  describe "EEVM.Precompiles dispatcher" do
    test "routes address 0x0A to KZGPointEval" do
      assert {:ok, output, @gas_cost} = EEVM.Precompiles.execute(0x0A, valid_input(), @gas_cost)
      assert byte_size(output) == 64
    end
  end

  defp valid_input do
    build_input([])
  end

  defp build_input(overrides) do
    commitment = Keyword.get(overrides, :commitment, :binary.copy(<<0x11>>, 48))
    versioned_hash = Keyword.get(overrides, :versioned_hash, compute_versioned_hash(commitment))
    z = Keyword.get(overrides, :z, <<123::unsigned-big-256>>)
    y = Keyword.get(overrides, :y, <<456::unsigned-big-256>>)
    proof = Keyword.get(overrides, :proof, :binary.copy(<<0x22>>, 48))

    <<versioned_hash::binary, z::binary, y::binary, commitment::binary, proof::binary>>
  end

  defp compute_versioned_hash(commitment) do
    digest = :crypto.hash(:sha256, commitment)
    <<_::unsigned-8, tail::binary-size(31)>> = digest
    <<0x01::unsigned-8, tail::binary>>
  end
end
