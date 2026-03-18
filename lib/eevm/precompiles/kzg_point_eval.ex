defmodule EEVM.Precompiles.KZGPointEval do
  @moduledoc """
  KZG point evaluation precompile — address `0x0A` (EIP-4844).

  ## EVM Concepts

  EIP-4844 (proto-danksharding) introduces **blob transactions** where large data
  blobs are carried outside normal calldata and represented on-chain by compact
  **KZG commitments**. Contracts do not process full blobs directly; they verify
  evaluation claims against commitments.

  This precompile performs that evaluation check flow:

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

  ## Elixir Learning Notes

  - Binary pattern matching (`<<...>>`) gives direct fixed-offset parsing with no
    manual indexing.
  - `:binary.decode_unsigned/1` converts 32-byte big-endian field elements to
    arbitrary-precision Elixir integers for range checks.
  - `:crypto.hash(:sha256, commitment)` computes the versioned hash preimage.

  ### Verification implementation note

  Full KZG proof verification requires trusted setup parameters and a native
  verifier (for example `c-kzg-4844` via `kzg_elixir`/`ckzg`). This project does
  not currently bundle that verifier. Therefore, this module implements all
  EIP-4844 parsing, gas metering, and deterministic validation rules, and treats
  the cryptographic proof step as successful when no verifier is available.
  """

  @gas_cost 50_000
  @field_elements_per_blob 4_096
  @bls_modulus 52_435_875_175_126_190_479_447_740_508_185_965_837_690_552_500_527_637_822_603_658_699_938_581_184_513
  @versioned_hash_version_kzg 0x01

  @spec execute(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()}
          | {:error,
             :out_of_gas
             | :invalid_input
             | :invalid_versioned_hash
             | :invalid_field_element
             | :proof_verification_failed}
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

  defp verify_proof(commitment, z, y, proof) do
    kzg_module = :"Elixir.KzgElixir"

    if Code.ensure_loaded?(kzg_module) and function_exported?(kzg_module, :verify_kzg_proof, 4) do
      case apply(kzg_module, :verify_kzg_proof, [commitment, z, y, proof]) do
        {:ok, true} -> :ok
        {:ok, false} -> {:error, :proof_verification_failed}
        {:error, _reason} -> {:error, :proof_verification_failed}
      end
    else
      :ok
    end
  end

  defp output_constants do
    <<@field_elements_per_blob::unsigned-big-256, @bls_modulus::unsigned-big-256>>
  end
end
