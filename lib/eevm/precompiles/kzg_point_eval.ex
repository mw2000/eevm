defmodule EEVM.Precompiles.KZGPointEval do
  @moduledoc """
  KZG point evaluation precompile — address `0x0A` (EIP-4844).

  The precompile flow:

  1. Validate the `versioned_hash` derived from the commitment.
  2. Validate field element bounds for the evaluation point `z` and value `y`.
  3. Verify the KZG proof for `(commitment, z, y, proof)`.

  ### Gas schedule

  Flat **50,000 gas** per call.

  ### Input format (exactly 192 bytes)

  - bytes `0..31`   — `versioned_hash` (32 bytes)
  - bytes `32..63`  — `z` evaluation point (32 bytes, big-endian field element)
  - bytes `64..95`  — `y` claimed evaluation (32 bytes, big-endian field element)
  - bytes `96..143` — `commitment` (48 bytes)
  - bytes `144..191` — `proof` (48 bytes)

  ### Output format

  Exactly 64 bytes: two big-endian uint256 values:

  - `FIELD_ELEMENTS_PER_BLOB` (`4096`)
  - `BLS_MODULUS`

  ### Proof verification

  The 48-byte commitment and proof are compressed G1 points (ZCash
  serialization, as in the consensus specs' `bytes_to_kzg_commitment`). They
  are decompressed and checked to be in G1, and the KZG check

      e(C − [y]G1, G2) = e(π, [τ]G2 − [z]G2)

  is evaluated in the equivalent form e(C − [y]G1 + [z]π, −G2) · e(π, [τ]G2) = 1:
  one G1 multi-scalar multiplication and one two-pair pairing check, both
  from `EEVM.Precompiles.Bls12381.Curve`. Of the trusted setup, only [τ]G2 is
  needed.
  """

  @behaviour EEVM.Precompile

  alias EEVM.Crypto.SHA256
  alias EEVM.Precompiles.Bls12381.Curve

  @gas_cost 50_000
  @field_elements_per_blob 4_096
  @bls_modulus 52_435_875_175_126_190_479_447_740_508_185_965_837_690_552_500_527_637_822_603_658_699_938_581_184_513
  @versioned_hash_version_kzg 0x01

  # −G2: the G2 generator with both y coefficients negated.
  @neg_g2_generator Curve.neg(Curve.g2_generator())

  # [τ]G2 from the KZG ceremony: `g2_monomial[1]` of the mainnet trusted setup
  # (c-kzg-4844 `trusted_setup.txt`, compressed b5bfd7dd8cdeb128...20c1def2),
  # decompressed and checked against the setup's [τ]G1 with
  # e([τ]G1, −G2)·e(G1, [τ]G2) = 1. Every valid proof depends on it.
  @tau_g2 {{0x185CBFEE53492714734429B7B38608E23926C911CCECEAC9A36851477BA4C60B087041DE621000EDC98EDADA20C1DEF2,
            0x15BFD7DD8CDEB128843BC287230AF38926187075CBFBEFA81009A2CE615AC53D2914E5870CB452D2AFAAAB24F3499F72},
           {0x014353BDB96B626DD7D5EE8599D1FCA2131569490E28DE18E82451A496A9C9794CE26D105941F383EE689BFBBB832A99,
            0x1666C54B0A32529503432FCAE0181B4BEF79DE09FC63671FDA5ED1BA9BFA07899495346F3D7AC9CD23048EF30D0A154F}}

  @spec execute(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()}
          | {:error,
             :out_of_gas
             | :invalid_input
             | :invalid_versioned_hash
             | :invalid_field_element
             | :proof_verification_failed}
  @impl true
  def execute(_input, gas_limit) when gas_limit < @gas_cost, do: {:error, :out_of_gas}

  def execute(input, _gas_limit) do
    with {:ok, parsed} <- parse_input(input),
         :ok <- validate_versioned_hash(parsed.versioned_hash, parsed.commitment),
         :ok <- validate_field_elements(parsed.z, parsed.y),
         :ok <- verify_proof(parsed.commitment, parsed.z, parsed.y, parsed.proof) do
      {:ok, output_constants(), @gas_cost}
    else
      {:error, _reason} = error -> error
    end
  end

  defp parse_input(input) when byte_size(input) != 192, do: {:error, :invalid_input}

  defp parse_input(
         <<versioned_hash::binary-size(32), z::binary-size(32), y::binary-size(32),
           commitment::binary-size(48), proof::binary-size(48)>>
       ) do
    {:ok,
     %{
       versioned_hash: versioned_hash,
       z: z,
       y: y,
       commitment: commitment,
       proof: proof
     }}
  end

  defp validate_versioned_hash(versioned_hash, commitment) do
    digest = SHA256.hash(commitment)
    <<_::unsigned-8, tail::binary-size(31)>> = digest
    expected = <<@versioned_hash_version_kzg::unsigned-8, tail::binary>>

    if versioned_hash == expected do
      :ok
    else
      {:error, :invalid_versioned_hash}
    end
  end

  defp validate_field_elements(z, y) do
    z_int = :binary.decode_unsigned(z)
    y_int = :binary.decode_unsigned(y)

    if z_int < @bls_modulus and y_int < @bls_modulus do
      :ok
    else
      {:error, :invalid_field_element}
    end
  end

  # e(C − [y]G1 + [z]π, −G2) · e(π, [τ]G2) = 1; see the moduledoc. Any
  # invalid encoding, or C or π outside G1, fails.
  defp verify_proof(commitment, z, y, proof) do
    z = :binary.decode_unsigned(z)
    y = :binary.decode_unsigned(y)

    with {:ok, c} <- decompress_g1(commitment),
         {:ok, pi} <- decompress_g1(proof),
         lhs = Curve.msm([{c, 1}, {Curve.g1_generator(), @bls_modulus - y}, {pi, z}]),
         true <- Curve.pairing_check([{lhs, @neg_g2_generator}, {pi, @tau_g2}]) do
      :ok
    else
      _ -> {:error, :proof_verification_failed}
    end
  end

  defp decompress_g1(bytes) do
    with {:ok, point} <- Curve.g1_decompress(bytes),
         true <- Curve.in_subgroup?(point),
         do: {:ok, point}
  end

  defp output_constants do
    <<@field_elements_per_blob::unsigned-big-256, @bls_modulus::unsigned-big-256>>
  end
end
