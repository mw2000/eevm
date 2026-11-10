defmodule EEVM.Crypto.SHA256 do
  @moduledoc """
  SHA-256 ([FIPS 180-4](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.180-4.pdf), §6.2)
  in pure Elixir.

  Used by the `0x02` precompile, EIP-7685 `requests_hash`, and EIP-4844
  versioned hashes.

  ## Example

      iex> EEVM.Crypto.SHA256.hash("abc") |> Base.encode16(case: :lower)
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  """

  import Bitwise

  # Every word is 32 bits, so all arithmetic stays on BEAM small integers.
  # Rotations mask before shifting left so no intermediate exceeds 32 bits.
  @mask 0xFFFFFFFF

  # §5.3.3: the first 32 bits of the fractional parts of the square roots of
  # the first eight primes.
  @initial_state {0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C,
                  0x1F83D9AB, 0x5BE0CD19}

  # §4.2.2: the first 32 bits of the fractional parts of the cube roots of the
  # first 64 primes.
  @round_constants [
    0x428A2F98,
    0x71374491,
    0xB5C0FBCF,
    0xE9B5DBA5,
    0x3956C25B,
    0x59F111F1,
    0x923F82A4,
    0xAB1C5ED5,
    0xD807AA98,
    0x12835B01,
    0x243185BE,
    0x550C7DC3,
    0x72BE5D74,
    0x80DEB1FE,
    0x9BDC06A7,
    0xC19BF174,
    0xE49B69C1,
    0xEFBE4786,
    0x0FC19DC6,
    0x240CA1CC,
    0x2DE92C6F,
    0x4A7484AA,
    0x5CB0A9DC,
    0x76F988DA,
    0x983E5152,
    0xA831C66D,
    0xB00327C8,
    0xBF597FC7,
    0xC6E00BF3,
    0xD5A79147,
    0x06CA6351,
    0x14292967,
    0x27B70A85,
    0x2E1B2138,
    0x4D2C6DFC,
    0x53380D13,
    0x650A7354,
    0x766A0ABB,
    0x81C2C92E,
    0x92722C85,
    0xA2BFE8A1,
    0xA81A664B,
    0xC24B8B70,
    0xC76C51A3,
    0xD192E819,
    0xD6990624,
    0xF40E3585,
    0x106AA070,
    0x19A4C116,
    0x1E376C08,
    0x2748774C,
    0x34B0BCB5,
    0x391C0CB3,
    0x4ED8AA4A,
    0x5B9CCA4F,
    0x682E6FF3,
    0x748F82EE,
    0x78A5636F,
    0x84C87814,
    0x8CC70208,
    0x90BEFFFA,
    0xA4506CEB,
    0xBEF9A3F7,
    0xC67178F2
  ]

  @doc """
  Returns the 32-byte SHA-256 digest of `message`.

  ## Example

      iex> EEVM.Crypto.SHA256.hash("") |> Base.encode16(case: :lower)
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  """
  @spec hash(binary()) :: <<_::256>>
  def hash(message) when is_binary(message) do
    {h0, h1, h2, h3, h4, h5, h6, h7} = absorb(message, byte_size(message), @initial_state)
    <<h0::32, h1::32, h2::32, h3::32, h4::32, h5::32, h6::32, h7::32>>
  end

  # Full 64-byte blocks are read straight from the message; only the tail is
  # copied to append the §5.1.1 padding: 0x80, zeros, then the bit length.
  defp absorb(<<block::binary-size(64), rest::binary>>, length, state),
    do: absorb(rest, length, compress(state, block))

  defp absorb(tail, length, state) do
    zeros = rem(119 - byte_size(tail), 64)
    padded = <<tail::binary, 0x80, 0::size(zeros)-unit(8), length * 8::64>>
    padded |> blocks() |> Enum.reduce(state, &compress(&2, &1))
  end

  defp blocks(<<block::binary-size(64), rest::binary>>), do: [block | blocks(rest)]
  defp blocks(<<>>), do: []

  # §6.2.2: expand the block into the 64-word schedule, run 64 rounds, and add
  # the result into the state.
  defp compress({h0, h1, h2, h3, h4, h5, h6, h7}, block) do
    {a, b, c, d, e, f, g, h} =
      rounds(@round_constants, schedule(block), h0, h1, h2, h3, h4, h5, h6, h7)

    {h0 + a &&& @mask, h1 + b &&& @mask, h2 + c &&& @mask, h3 + d &&& @mask, h4 + e &&& @mask,
     h5 + f &&& @mask, h6 + g &&& @mask, h7 + h &&& @mask}
  end

  defp rounds([k | ks], [w | ws], a, b, c, d, e, f, g, h) do
    t1 = h + big_sigma1(e) + choose(e, f, g) + k + w
    t2 = big_sigma0(a) + majority(a, b, c)
    rounds(ks, ws, t1 + t2 &&& @mask, a, b, c, d + t1 &&& @mask, e, f, g)
  end

  defp rounds([], [], a, b, c, d, e, f, g, h), do: {a, b, c, d, e, f, g, h}

  # W[t] = σ1(W[t-2]) + W[t-7] + σ0(W[t-15]) + W[t-16] for t in 16..63. The
  # schedule is built newest first, so W[t-2] is the second element.
  defp schedule(block) do
    words = for <<word::32 <- block>>, do: word
    words |> Enum.reverse() |> extend(48) |> Enum.reverse()
  end

  defp extend(newest_first, 0), do: newest_first

  defp extend([_, w2, _, _, _, _, w7, _, _, _, _, _, _, _, w15, w16 | _] = newest_first, count) do
    word = small_sigma1(w2) + w7 + small_sigma0(w15) + w16 &&& @mask
    extend([word | newest_first], count - 1)
  end

  # §4.1.2 functions.
  defp choose(x, y, z), do: bxor(x &&& y, bnot(x) &&& z)
  defp majority(x, y, z), do: bxor(bxor(x &&& y, x &&& z), y &&& z)
  defp big_sigma0(x), do: bxor(bxor(rotr(x, 2), rotr(x, 13)), rotr(x, 22))
  defp big_sigma1(x), do: bxor(bxor(rotr(x, 6), rotr(x, 11)), rotr(x, 25))
  defp small_sigma0(x), do: bxor(bxor(rotr(x, 7), rotr(x, 18)), x >>> 3)
  defp small_sigma1(x), do: bxor(bxor(rotr(x, 17), rotr(x, 19)), x >>> 10)

  defp rotr(x, n), do: x >>> n ||| (x &&& (1 <<< n) - 1) <<< (32 - n)
end
