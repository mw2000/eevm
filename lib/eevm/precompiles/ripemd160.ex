defmodule EEVM.Precompiles.RIPEMD160 do
  @moduledoc """
  RIPEMD-160 precompile — address `0x03`.

  ## EVM Concepts

  RIPEMD-160 is a 160-bit (20-byte) cryptographic hash function developed in
  Europe as an alternative to SHA-1. Its primary use in Ethereum is
  **Bitcoin address derivation**: a Bitcoin address is `RIPEMD160(SHA256(pubkey))`,
  so on-chain Bitcoin light-client contracts need this precompile to reconstruct
  and verify addresses without trusting off-chain computation.

  ### Output format (Yellow Paper §E.2)

  Even though the digest is only 20 bytes, the precompile **always returns
  32 bytes**: the 20-byte hash is **right-aligned** within the 32-byte word,
  with 12 zero bytes prepended on the left. This matches the EVM's natural
  word size and lets callers use the result directly as a `bytes32` or `address`
  value without extra masking.

  ```
  [ 0x00 × 12 | RIPEMD160(input) × 20 ]
  └────────────────────────── 32 bytes ──┘
  ```

  ### Gas schedule

  | Component | Cost |
  |-----------|------|
  | Base      | 600  |
  | Per word  | 120 (one word = 32 bytes, rounded up) |

  The higher base cost reflects the fact that RIPEMD-160 is slower than both
  Keccak-256 and SHA-256 in typical hardware implementations.

  ## Elixir Learning Notes

  - `:crypto.hash(:ripemd160, data)` produces a 20-byte binary. Erlang's
    `:crypto` NIF supports RIPEMD-160 via OpenSSL.
  - `<<0::96, hash::binary>>` is binary construction syntax. `0::96` emits
    96 zero bits (= 12 zero bytes), and `hash::binary` appends the raw hash
    bytes, yielding the required 32-byte output in one expression.
  """

  @behaviour EEVM.Precompile

  @base_cost 600
  @word_cost 120

  @doc """
  Executes the RIPEMD-160 precompile.

  Hashes `input` with RIPEMD-160 and returns a 32-byte binary: 12 zero bytes
  followed by the 20-byte digest. Gas charged is
  `600 + 120 * ceil(byte_size(input) / 32)`.

  ## Examples

      iex> {:ok, out, _gas} = EEVM.Precompiles.RIPEMD160.execute(<<>>, 10_000)
      iex> byte_size(out)
      32
      iex> binary_part(out, 0, 12)
      <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>

      iex> EEVM.Precompiles.RIPEMD160.execute(<<1::256>>, 5)
      {:error, :out_of_gas}

  """
  @spec execute(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :out_of_gas}
  @impl true
  def execute(input, gas_limit) do
    cost = @base_cost + @word_cost * word_count(input)

    if cost > gas_limit do
      {:error, :out_of_gas}
    else
      hash = :crypto.hash(:ripemd160, input)
      # Left-pad the 20-byte digest with 12 zero bytes to fill a 32-byte word.
      {:ok, <<0::96, hash::binary>>, cost}
    end
  end

  # ceil(byte_size / 32) via the (n + 31) / 32 trick.
  defp word_count(input), do: div(byte_size(input) + 31, 32)
end
