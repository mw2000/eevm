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
  are decompressed here, and the KZG check

      e(C − [y]G1, G2) = e(π, [τ]G2 − [z]G2)

  is evaluated in the equivalent form e(C − [y]G1 + [z]π, −G2) · e(π, [τ]G2) = 1.
  That needs one G1 multi-scalar multiplication and one two-pair pairing,
  both from the BLS12-381 NIF used by the EIP-2537 precompiles, which also
  checks that C and π are in G1. Of the trusted setup, only [τ]G2 is needed.
  """

  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.Bls12381.Nif

  @gas_cost 50_000
  @field_elements_per_blob 4_096
  @bls_modulus 52_435_875_175_126_190_479_447_740_508_185_965_837_690_552_500_527_637_822_603_658_699_938_581_184_513
  @versioned_hash_version_kzg 0x01

  # BLS12-381 base field modulus.
  @fp_modulus 0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAB

  # Points in the EIP-2537 encoding the NIF takes: each Fp coordinate as 64
  # bytes (16 zero bytes, then 48 big-endian, which is what `::512` produces
  # for a value below 2^384), Fp2 as c0 then c1.
  @g1_generator_coordinates [
    0x17F1D3A73197D7942695638C4FA9AC0FC3688C4F9774B905A14E3A3F171BAC586C55E83FF97A1AEFFB3AF00ADB22C6BB,
    0x08B3F481E3AAA0F1A09E30ED741D8AE4FCF5E095D5D00AF600DB18CB2C04B3EDD03CC744A2888AE40CAA232946C5E7E1
  ]
  @g1_generator for coordinate <- @g1_generator_coordinates, into: <<>>, do: <<coordinate::512>>

  # −G2: the G2 generator with both y coefficients negated.
  @neg_g2_generator_coordinates [
    0x024AA2B2F08F0A91260805272DC51051C6E47AD4FA403B02B4510B647AE3D1770BAC0326A805BBEFD48056C8C121BDB8,
    0x13E02B6052719F607DACD3A088274F65596BD0D09920B61AB5DA61BBDC7F5049334CF11213945D57E5AC7D055D042B7E,
    0x0D1B3CC2C7027888BE51D9EF691D77BCB679AFDA66C73F17F9EE3837A55024F78C71363275A75D75D86BAB79F74782AA,
    0x13FA4D4A0AD8B1CE186ED5061789213D993923066DDDAF1040BC3FF59F825C78DF74F2D75467E25E0F55F8A00FA030ED
  ]
  @neg_g2_generator for coordinate <- @neg_g2_generator_coordinates,
                        into: <<>>,
                        do: <<coordinate::512>>

  # [τ]G2 from the KZG ceremony: `g2_monomial[1]` of the mainnet trusted setup
  # (c-kzg-4844 `trusted_setup.txt`, compressed b5bfd7dd8cdeb128...20c1def2),
  # decompressed and checked against the setup's [τ]G1 with
  # e([τ]G1, −G2)·e(G1, [τ]G2) = 1. Every valid proof depends on it.
  @tau_g2_coordinates [
    0x185CBFEE53492714734429B7B38608E23926C911CCECEAC9A36851477BA4C60B087041DE621000EDC98EDADA20C1DEF2,
    0x15BFD7DD8CDEB128843BC287230AF38926187075CBFBEFA81009A2CE615AC53D2914E5870CB452D2AFAAAB24F3499F72,
    0x014353BDB96B626DD7D5EE8599D1FCA2131569490E28DE18E82451A496A9C9794CE26D105941F383EE689BFBBB832A99,
    0x1666C54B0A32529503432FCAE0181B4BEF79DE09FC63671FDA5ED1BA9BFA07899495346F3D7AC9CD23048EF30D0A154F
  ]
  @tau_g2 for coordinate <- @tau_g2_coordinates, into: <<>>, do: <<coordinate::512>>

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
    digest = :crypto.hash(:sha256, commitment)
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
  # invalid encoding, or C or π outside G1 (rejected by the NIF), fails.
  defp verify_proof(commitment, z, y, proof) do
    z = :binary.decode_unsigned(z)
    y = :binary.decode_unsigned(y)

    with {:ok, c} <- decompress_g1(commitment),
         {:ok, pi} <- decompress_g1(proof),
         {:ok, lhs} <-
           nif_call(
             &Nif.g1_msm/1,
             c <> <<1::256>> <> @g1_generator <> <<@bls_modulus - y::256>> <> pi <> <<z::256>>
           ),
         {:ok, <<1::256>>} <- nif_call(&Nif.pairing/1, lhs <> @neg_g2_generator <> pi <> @tau_g2) do
      :ok
    else
      _ -> {:error, :proof_verification_failed}
    end
  end

  # Decompresses a 48-byte G1 point (ZCash serialization) into the EIP-2537
  # encoding. The top three bits are flags: compressed (must be set),
  # infinity, and the sign that picks y > (p − 1)/2. Subgroup membership is
  # checked later, by the NIF.
  defp decompress_g1(<<1::1, 1::1, 0::1, 0::381>>), do: {:ok, <<0::1024>>}

  defp decompress_g1(<<1::1, 0::1, sign::1, x::381>>) when x < @fp_modulus do
    y_squared = rem(x * x * x + 4, @fp_modulus)

    # p ≡ 3 (mod 4), so a square root of a square a is a^((p + 1)/4).
    y =
      :crypto.mod_pow(y_squared, div(@fp_modulus + 1, 4), @fp_modulus)
      |> :binary.decode_unsigned()

    if rem(y * y, @fp_modulus) == y_squared do
      y = if y > @fp_modulus - y == (sign == 1), do: y, else: @fp_modulus - y
      {:ok, <<0::128, x::384, 0::128, y::384>>}
    else
      {:error, :invalid_point}
    end
  end

  defp decompress_g1(_bytes), do: {:error, :invalid_point}

  # The NIF returns {:ok, {:ok, bytes}} with bytes as a list or binary, or an error.
  defp nif_call(fun, input) do
    case fun.(input) do
      {:ok, {:ok, output}} -> {:ok, IO.iodata_to_binary(output)}
      _error -> :error
    end
  end

  defp output_constants do
    <<@field_elements_per_blob::unsigned-big-256, @bls_modulus::unsigned-big-256>>
  end
end
