defmodule EEVM.Precompiles.SHA256 do
  @moduledoc """
  SHA-256 precompile — address `0x02`.

  ## EVM Concepts

  SHA-256 is the second built-in contract and the only precompile that uses a
  different hash function than the EVM's native Keccak-256. It is included
  primarily for **Bitcoin interoperability**: Bitcoin addresses and block headers
  are SHA-256 based, so on-chain verification of Bitcoin proofs requires access
  to the function.

  SHA-256 also appears in:

  - **EIP-197 (BN256)** pairing checks, whose inputs are sometimes hashed with
    SHA-256 before being passed on-chain.
  - **Beacon chain / consensus layer** — the Ethereum consensus layer uses
    SHA-256 (not Keccak) for its Merkle tree.

  ### Gas schedule (Yellow Paper §E.2)

  | Component | Cost |
  |-----------|------|
  | Base      | 60   |
  | Per word  | 12 (one word = 32 bytes, rounded up) |

  ### Output format

  Always 32 bytes — the raw SHA-256 digest.

  ## Elixir Learning Notes

  - `:crypto.hash(:sha256, data)` calls into Erlang's OpenSSL-backed `:crypto`
    NIF (native implemented function). It is significantly faster than a pure
    Elixir implementation and requires no extra dependencies.
  - The atom `:sha256` maps to OpenSSL's `EVP_sha256` digest under the hood;
    Erlang exposes the full OpenSSL digest catalogue this way.
  """

  @base_cost 60
  @word_cost 12

  @doc """
  Executes the SHA-256 precompile.

  Hashes `input` with SHA-256 and returns the 32-byte digest, charging
  `60 + 12 * ceil(byte_size(input) / 32)` gas.

  ## Examples

      iex> {:ok, digest, _gas} = EEVM.Precompiles.SHA256.execute(<<>>, 1_000)
      iex> byte_size(digest)
      32

      iex> EEVM.Precompiles.SHA256.execute(<<1::256>>, 5)
      {:error, :out_of_gas}

  """
  @spec execute(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :out_of_gas}
  def execute(input, gas_limit) do
    cost = @base_cost + @word_cost * word_count(input)

    if cost > gas_limit do
      {:error, :out_of_gas}
    else
      {:ok, :crypto.hash(:sha256, input), cost}
    end
  end

  # ceil(byte_size / 32) via the (n + 31) / 32 trick.
  defp word_count(input), do: div(byte_size(input) + 31, 32)
end
