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

    test "a well-formed but incorrect proof fails" do
      # The correct proof for this commitment, z, and y, with y off by one.
      input =
        build_input(
          y: <<0x2BF4E1F980EB94661A21AFFC4D7E6E56F214FE3E7DC4D20B98C66FFD43CABEB1::256>>
        )

      assert {:error, :proof_verification_failed} = KZGPointEval.execute(input, @gas_cost)
    end

    test "an all-zero commitment and proof fail (compression flag not set)" do
      zeros = :binary.copy(<<0>>, 48)
      input = build_input(commitment: zeros, proof: zeros)
      assert {:error, :proof_verification_failed} = KZGPointEval.execute(input, @gas_cost)
    end

    test "output format is two 32-byte constants" do
      assert {:ok, output, @gas_cost} = KZGPointEval.execute(valid_input(), @gas_cost)

      <<field_elements_per_blob::unsigned-big-256, bls_modulus::unsigned-big-256>> = output

      assert field_elements_per_blob == @field_elements_per_blob
      assert bls_modulus == @bls_modulus
    end
  end

  describe "official verify_kzg_proof vectors" do
    # c-kzg-4844's tests/verify_kzg_proof/kzg-mainnet (see
    # test/fixtures/precompiles/README.md). `output` is true for a valid proof
    # and false or null otherwise. Vectors whose commitment or proof is not 48
    # bytes (or z, y not 32) cannot be expressed as a 192-byte precompile input.
    for vector <-
          "test/fixtures/precompiles/kzg_verify_proof_vectors.json"
          |> File.read!()
          |> Jason.decode!(),
        input =
          Map.new(vector["input"], fn {key, "0x" <> hex} ->
            {key, Base.decode16!(hex, case: :mixed)}
          end),
        byte_size(input["commitment"]) == 48 and byte_size(input["proof"]) == 48 and
          byte_size(input["z"]) == 32 and byte_size(input["y"]) == 32 do
      @input input
      @valid vector["output"] == true
      test vector["name"] do
        input =
          build_input(
            commitment: @input["commitment"],
            z: @input["z"],
            y: @input["y"],
            proof: @input["proof"]
          )

        if @valid do
          assert {:ok, _output, @gas_cost} = KZGPointEval.execute(input, @gas_cost)
        else
          assert {:error, _reason} = KZGPointEval.execute(input, @gas_cost)
        end
      end
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

  # Defaults to c-kzg-4844's verify_kzg_proof_case_correct_proof_2_2, a valid proof.
  defp build_input(overrides) do
    commitment =
      Keyword.get(
        overrides,
        :commitment,
        Base.decode16!(
          "A421E229565952CFFF4EF3517100A97DA1D4FE57956FA50A442F92AF03B1BF37ADACC8AD4ED209B31287EA5BB94D9D06"
        )
      )

    versioned_hash = Keyword.get(overrides, :versioned_hash, compute_versioned_hash(commitment))
    z = Keyword.get(overrides, :z, <<2::unsigned-big-256>>)

    y =
      Keyword.get(
        overrides,
        :y,
        <<0x2BF4E1F980EB94661A21AFFC4D7E6E56F214FE3E7DC4D20B98C66FFD43CABEB0::256>>
      )

    proof =
      Keyword.get(
        overrides,
        :proof,
        Base.decode16!(
          "89012990B0CA02775BD9DF8145F6C936444B83F54DF1F5F274FB4312800A6505DD000EE8EC7B0EA6D72092A3DAF0BFFB"
        )
      )

    <<versioned_hash::binary, z::binary, y::binary, commitment::binary, proof::binary>>
  end

  defp compute_versioned_hash(commitment) do
    digest = :crypto.hash(:sha256, commitment)
    <<_::unsigned-8, tail::binary-size(31)>> = digest
    <<0x01::unsigned-8, tail::binary>>
  end
end
