defmodule EEVM.Precompiles.Blake2F do
  @moduledoc """
  Blake2f precompile — address `0x09` (EIP-152).

  ## EVM Concepts

  EIP-152 adds the Blake2b compression function `F` as an EVM precompile so
  contracts can verify data structures from ecosystems that rely on BLAKE2,
  especially **Zcash block headers** and **Equihash proofs**, without expensive
  in-EVM emulation.

  This also benefits interoperability with chains and protocols that use
  Blake2-based primitives, including **Filecoin proof systems**, where on-chain
  verification needs the exact compression round function.

  ### Gas schedule

  Gas cost is exactly the `rounds` field from input bytes `0..3` (uint32,
  big-endian).

  ### Input format

  Input must be **exactly 213 bytes**:

  - bytes `0..3`   — `rounds` (`uint32`, big-endian)
  - bytes `4..67`  — `h` (8 × 64-bit words, little-endian)
  - bytes `68..195` — `m` (16 × 64-bit words, little-endian)
  - bytes `196..211` — `t` (2 × 64-bit words, little-endian)
  - byte `212`     — `f` final block flag (`0` or `1` only)

  Output is 64 bytes: the 8 updated state words in little-endian.

  ## Elixir Learning Notes

  - Cryptographic compression can be implemented in pure Elixir with
    `import Bitwise` plus explicit 64-bit masking (`0xFFFFFFFFFFFFFFFF`) after
    additions to preserve modulo `2^64` behavior.
  - Binary pattern matching with little-endian fields (`<<w::little-64>>`) is
    ideal for parsing EIP-152 state/message/counter words directly from input.
  - Tuple-based state management (`put_elem/3`, `elem/2`) is a practical fit for
    fixed-size vectors like Blake2b's 16-word working vector.
  """

  import Bitwise

  @mask 0xFFFFFFFFFFFFFFFF

  @iv {
    0x6A09E667F3BCC908,
    0xBB67AE8584CAA73B,
    0x3C6EF372FE94F82B,
    0xA54FF53A5F1D36F1,
    0x510E527FADE682D1,
    0x9B05688C2B3E6C1F,
    0x1F83D9ABFB41BD6B,
    0x5BE0CD19137E2179
  }

  @sigma {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
    {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4},
    {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8},
    {9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13},
    {2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9},
    {12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11},
    {13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10},
    {6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5},
    {10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0}
  }

  @doc """
  Executes the Blake2f precompile.

  Returns `{:ok, output, gas_used}` on success where `output` is 64 bytes and
  `gas_used == rounds`.

  Returns:
  - `{:error, :invalid_input}` if input length is not 213 bytes or final flag is
    not `0` or `1`
  - `{:error, :out_of_gas}` if `gas_limit < rounds`
  """
  @spec execute(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :invalid_input | :out_of_gas}
  def execute(input, gas_limit) do
    with {:ok, rounds, h, m, t, final_block?} <- parse_input(input),
         :ok <- ensure_gas(rounds, gas_limit) do
      output_words = compress(h, m, t, final_block?, rounds)
      {:ok, encode_words(output_words), rounds}
    else
      {:error, _reason} = error -> error
    end
  end

  defp ensure_gas(rounds, gas_limit) when rounds > gas_limit, do: {:error, :out_of_gas}
  defp ensure_gas(_rounds, _gas_limit), do: :ok

  defp parse_input(input) when byte_size(input) != 213, do: {:error, :invalid_input}

  defp parse_input(
         <<rounds::unsigned-big-32, h_bin::binary-size(64), m_bin::binary-size(128),
           t_bin::binary-size(16), f::unsigned-8>>
       )
       when f in [0, 1] do
    {:ok, rounds, decode_words(h_bin, 8), decode_words(m_bin, 16), decode_words(t_bin, 2), f == 1}
  end

  defp parse_input(_), do: {:error, :invalid_input}

  defp decode_words(bin, count) do
    words = for <<word::little-64 <- bin>>, do: word

    if length(words) == count do
      List.to_tuple(words)
    else
      raise ArgumentError, "invalid Blake2f word count"
    end
  end

  defp encode_words(words) do
    for i <- 0..7, into: <<>> do
      <<elem(words, i)::little-64>>
    end
  end

  defp compress(h, m, t, final_block?, rounds) do
    v0 = init_vector(h, t, final_block?)

    v_final =
      if rounds == 0 do
        v0
      else
        Enum.reduce(0..(rounds - 1), v0, fn round, v ->
          round_mix(v, m, elem(@sigma, rem(round, 10)))
        end)
      end

    0..7
    |> Enum.map(fn i ->
      band(bxor(elem(h, i), bxor(elem(v_final, i), elem(v_final, i + 8))), @mask)
    end)
    |> List.to_tuple()
  end

  defp init_vector(h, t, final_block?) do
    {
      elem(h, 0),
      elem(h, 1),
      elem(h, 2),
      elem(h, 3),
      elem(h, 4),
      elem(h, 5),
      elem(h, 6),
      elem(h, 7),
      elem(@iv, 0),
      elem(@iv, 1),
      elem(@iv, 2),
      elem(@iv, 3),
      bxor(elem(@iv, 4), elem(t, 0)),
      bxor(elem(@iv, 5), elem(t, 1)),
      if(final_block?, do: bxor(elem(@iv, 6), @mask), else: elem(@iv, 6)),
      elem(@iv, 7)
    }
  end

  defp round_mix(v, m, s) do
    v
    |> g(0, 4, 8, 12, elem(m, elem(s, 0)), elem(m, elem(s, 1)))
    |> g(1, 5, 9, 13, elem(m, elem(s, 2)), elem(m, elem(s, 3)))
    |> g(2, 6, 10, 14, elem(m, elem(s, 4)), elem(m, elem(s, 5)))
    |> g(3, 7, 11, 15, elem(m, elem(s, 6)), elem(m, elem(s, 7)))
    |> g(0, 5, 10, 15, elem(m, elem(s, 8)), elem(m, elem(s, 9)))
    |> g(1, 6, 11, 12, elem(m, elem(s, 10)), elem(m, elem(s, 11)))
    |> g(2, 7, 8, 13, elem(m, elem(s, 12)), elem(m, elem(s, 13)))
    |> g(3, 4, 9, 14, elem(m, elem(s, 14)), elem(m, elem(s, 15)))
  end

  defp g(v, a, b, c, d, x, y) do
    va0 = elem(v, a)
    vb0 = elem(v, b)
    vc0 = elem(v, c)
    vd0 = elem(v, d)

    va1 = add64(add64(va0, vb0), x)
    vd1 = rotr64(bxor(vd0, va1), 32)
    vc1 = add64(vc0, vd1)
    vb1 = rotr64(bxor(vb0, vc1), 24)

    va2 = add64(add64(va1, vb1), y)
    vd2 = rotr64(bxor(vd1, va2), 16)
    vc2 = add64(vc1, vd2)
    vb2 = rotr64(bxor(vb1, vc2), 63)

    v
    |> put_elem(a, va2)
    |> put_elem(b, vb2)
    |> put_elem(c, vc2)
    |> put_elem(d, vd2)
  end

  defp add64(a, b), do: band(a + b, @mask)

  defp rotr64(x, n) do
    x64 = band(x, @mask)
    bor(bsr(x64, n), band(bsl(x64, 64 - n), @mask))
  end
end
