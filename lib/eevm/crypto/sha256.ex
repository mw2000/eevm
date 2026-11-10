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

  @compile {:inline,
            choose: 3,
            majority: 3,
            big_sigma0: 1,
            big_sigma1: 1,
            small_sigma0: 1,
            small_sigma1: 1,
            spread: 1}

  # §5.3.3: the first 32 bits of the fractional parts of the square roots of
  # the first eight primes.
  @initial_state {0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C,
                  0x1F83D9AB, 0x5BE0CD19}

  # §4.2.2: the first 32 bits of the fractional parts of the cube roots of the
  # first 64 primes.
  @round_constants {
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
  }

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

  # §6.2.2: 64 rounds over the working variables a..h, then add them into the
  # state. The message schedule is a sliding window w0..w15 of
  # W[t]..W[t+15], so a round needs no list or tuple: it consumes w0 and
  # appends W[t+16] = σ1(W[t+14]) + W[t+9] + σ0(W[t+1]) + W[t].
  defp compress(
         {h0, h1, h2, h3, h4, h5, h6, h7},
         <<w0::32, w1::32, w2::32, w3::32, w4::32, w5::32, w6::32, w7::32, w8::32, w9::32,
           w10::32, w11::32, w12::32, w13::32, w14::32, w15::32>>
       ) do
    {a, b, c, d, e, f, g, h} =
      rounds(
        0,
        h0,
        h1,
        h2,
        h3,
        h4,
        h5,
        h6,
        h7,
        w0,
        w1,
        w2,
        w3,
        w4,
        w5,
        w6,
        w7,
        w8,
        w9,
        w10,
        w11,
        w12,
        w13,
        w14,
        w15
      )

    {h0 + a &&& @mask, h1 + b &&& @mask, h2 + c &&& @mask, h3 + d &&& @mask, h4 + e &&& @mask,
     h5 + f &&& @mask, h6 + g &&& @mask, h7 + h &&& @mask}
  end

  defp rounds(64, a, b, c, d, e, f, g, h, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _),
    do: {a, b, c, d, e, f, g, h}

  defp rounds(
         t,
         a,
         b,
         c,
         d,
         e,
         f,
         g,
         h,
         w0,
         w1,
         w2,
         w3,
         w4,
         w5,
         w6,
         w7,
         w8,
         w9,
         w10,
         w11,
         w12,
         w13,
         w14,
         w15
       ) do
    t1 = h + big_sigma1(e) + choose(e, f, g) + elem(@round_constants, t) + w0
    t2 = big_sigma0(a) + majority(a, b, c)
    # The last 16 rounds read no new schedule words.
    w16 = if t < 48, do: small_sigma1(w14) + w9 + small_sigma0(w1) + w0 &&& @mask, else: 0

    rounds(
      t + 1,
      t1 + t2 &&& @mask,
      a,
      b,
      c,
      d + t1 &&& @mask,
      e,
      f,
      g,
      w1,
      w2,
      w3,
      w4,
      w5,
      w6,
      w7,
      w8,
      w9,
      w10,
      w11,
      w12,
      w13,
      w14,
      w15,
      w16
    )
  end

  # §4.1.2 functions. Every rotation here is by at most 25 bits, so copying
  # the word's low 26 bits above bit 32 (`spread/1`, still a small integer)
  # turns ROTR^n(x) into the single shift `spread(x) >>> n`, masked to 32 bits.
  defp choose(x, y, z), do: bxor(x &&& y, bnot(x) &&& z)
  defp majority(x, y, z), do: bxor(bxor(x &&& y, x &&& z), y &&& z)

  defp big_sigma0(x) do
    s = spread(x)
    bxor(bxor(s >>> 2, s >>> 13), s >>> 22) &&& @mask
  end

  defp big_sigma1(x) do
    s = spread(x)
    bxor(bxor(s >>> 6, s >>> 11), s >>> 25) &&& @mask
  end

  defp small_sigma0(x) do
    s = spread(x)
    bxor(bxor(s >>> 7, s >>> 18), x >>> 3) &&& @mask
  end

  defp small_sigma1(x) do
    s = spread(x)
    bxor(bxor(s >>> 17, s >>> 19), x >>> 10) &&& @mask
  end

  defp spread(x), do: x ||| (x &&& 0x3FFFFFF) <<< 32
end
