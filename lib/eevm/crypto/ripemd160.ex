defmodule EEVM.Crypto.RIPEMD160 do
  @moduledoc """
  RIPEMD-160 in pure Elixir, as specified by Dobbertin, Bosselaers and
  Preneel, ["RIPEMD-160: A Strengthened Version of RIPEMD"](https://homes.esat.kuleuven.be/~bosselae/ripemd160.html)
  (1996). Used by the `0x03` precompile.

  Each 64-byte block runs through two parallel lines of five 16-step
  rounds, which are then combined into the 160-bit state. Words are
  little-endian, like MD4's.

  ## Example

      iex> EEVM.Crypto.RIPEMD160.hash("abc") |> Base.encode16(case: :lower)
      "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc"
  """

  import Bitwise

  # Every word is 32 bits, so all arithmetic stays on BEAM small integers.
  @mask 0xFFFFFFFF

  @compile {:inline, f: 4, rotl: 2}

  @initial_state {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0}

  # Message word selected by each step, round by round (r and r' in the paper).
  @left_words [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8],
    [3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12],
    [1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2],
    [4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13]
  ]

  @right_words [
    [5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12],
    [6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2],
    [15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13],
    [8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14],
    [12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11]
  ]

  # Left-rotation amounts (s and s').
  @left_shifts [
    [11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8],
    [7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12],
    [11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5],
    [11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12],
    [9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6]
  ]

  @right_shifts [
    [8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6],
    [9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11],
    [9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5],
    [15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8],
    [8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11]
  ]

  # Each round's boolean function (1..5) and additive constant (K and K').
  # The right line runs the functions in reverse order.
  @left_rounds [
    {1, 0x00000000},
    {2, 0x5A827999},
    {3, 0x6ED9EBA1},
    {4, 0x8F1BBCDC},
    {5, 0xA953FD4E}
  ]
  @right_rounds [
    {5, 0x50A28BE6},
    {4, 0x5C4DD124},
    {3, 0x6D703EF3},
    {2, 0x7A6D76E9},
    {1, 0x00000000}
  ]

  # ── Compile-time code generation ──────────────────────────────────────────
  #
  # Each line is 80 steps whose word index, rotation, boolean function and
  # constant are all fixed, so the steps are unrolled at compile time from the
  # tables above. A step updates (a, b, c, d, e) to
  # (e, rotl(a + f(b, c, d) + X[word] + K, shift) + e, b, rotl(c, 10), d);
  # the generated code keeps five variables and renames them each step.

  var = fn name -> Macro.var(name, __MODULE__) end
  words = for i <- 0..15, do: var.(:"x#{i}")

  line = fn rounds, word_table, shift_table, prefix ->
    steps =
      [rounds, word_table, shift_table]
      |> Enum.zip()
      |> Enum.flat_map(fn {{function, constant}, round_words, round_shifts} ->
        Enum.zip_with(round_words, round_shifts, &{function, constant, &1, &2})
      end)

    initial = Enum.map(~w(a b c d e)a, &var.(:"#{prefix}#{&1}0"))

    {body, final, _} =
      Enum.reduce(steps, {[], initial, 1}, fn {function, constant, word, shift},
                                              {body, [a, b, c, d, e], step} ->
        t = var.(:"#{prefix}t#{step}")
        c_rotated = var.(:"#{prefix}c#{step}")

        step_code =
          quote do
            unquote(t) =
              rotl(
                unquote(a) + f(unquote(function), unquote(b), unquote(c), unquote(d)) +
                  unquote(Enum.at(words, word)) + unquote(constant) &&& @mask,
                unquote(shift)
              ) + unquote(e) &&& @mask

            unquote(c_rotated) = rotl(unquote(c), 10)
          end

        {[step_code | body], [e, t, b, c_rotated, d], step + 1}
      end)

    {Enum.reverse(body), initial, final}
  end

  {left_body, left_initial, [la, lb, lc, ld, le]} =
    line.(@left_rounds, @left_words, @left_shifts, "l")

  {right_body, right_initial, [ra, rb, rc, rd, re]} =
    line.(@right_rounds, @right_words, @right_shifts, "r")

  @doc """
  Returns the 20-byte RIPEMD-160 digest of `message`.

  ## Example

      iex> EEVM.Crypto.RIPEMD160.hash("") |> Base.encode16(case: :lower)
      "9c1185a5c5e9fc54612808977ee8f548b2258d31"
  """
  @spec hash(binary()) :: <<_::160>>
  def hash(message) when is_binary(message) do
    {h0, h1, h2, h3, h4} = absorb(message, byte_size(message), @initial_state)
    <<h0::little-32, h1::little-32, h2::little-32, h3::little-32, h4::little-32>>
  end

  # Full 64-byte blocks are read in place; only the tail is copied to append
  # MD4-style padding: 0x80, zeros, then the bit length as a little-endian
  # 64-bit word.
  defp absorb(<<block::binary-size(64), rest::binary>>, length, state),
    do: absorb(rest, length, compress(state, block))

  defp absorb(tail, length, state) do
    zeros = rem(119 - byte_size(tail), 64)
    padded = <<tail::binary, 0x80, 0::size(zeros)-unit(8), length * 8::little-64>>
    padded |> blocks() |> Enum.reduce(state, &compress(&2, &1))
  end

  defp blocks(<<block::binary-size(64), rest::binary>>), do: [block | blocks(rest)]
  defp blocks(<<>>), do: []

  # Both lines start from the state; their results are combined crosswise.
  defp compress(
         {h0, h1, h2, h3, h4},
         <<unquote_splicing(Enum.map(words, &quote(do: unquote(&1) :: little - 32)))>>
       ) do
    {unquote_splicing(left_initial)} = {h0, h1, h2, h3, h4}
    {unquote_splicing(right_initial)} = {h0, h1, h2, h3, h4}
    unquote_splicing(left_body)
    unquote_splicing(right_body)

    {h1 + unquote(lc) + unquote(rd) &&& @mask, h2 + unquote(ld) + unquote(re) &&& @mask,
     h3 + unquote(le) + unquote(ra) &&& @mask, h4 + unquote(la) + unquote(rb) &&& @mask,
     h0 + unquote(lb) + unquote(rc) &&& @mask}
  end

  # The five boolean functions. `bnot/1` yields a negative integer, but only
  # the low 32 bits of these bitwise results matter, and the caller masks
  # the sum they feed into.
  defp f(1, x, y, z), do: bxor(bxor(x, y), z)
  defp f(2, x, y, z), do: (x &&& y) ||| (bnot(x) &&& z)
  defp f(3, x, y, z), do: bxor(x ||| bnot(y), z)
  defp f(4, x, y, z), do: (x &&& z) ||| (y &&& bnot(z))
  defp f(5, x, y, z), do: bxor(x, y ||| bnot(z))

  defp rotl(x, n), do: (x &&& (1 <<< (32 - n)) - 1) <<< n ||| x >>> (32 - n)
end
