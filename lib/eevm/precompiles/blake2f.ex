defmodule EEVM.Precompiles.Blake2F do
  @moduledoc """
  Blake2f precompile — address `0x09` (EIP-152).

  Implements the Blake2b compression function `F`.

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
  """

  @behaviour EEVM.Precompile

  import Bitwise

  # Performance: an 8,000,000-round call (the largest in the official
  # stPreCompiledContracts2 Blake2f fixtures) took ~67 s with plain 64-bit
  # words. Three choices bring it to a few seconds:
  #
  # 1. BEAM small integers hold 60 bits, so 64-bit words are heap-allocated
  #    bignums and every add, xor, and shift on them allocates. Each word is
  #    split into 32-bit halves (`hi`, `lo`) so all arithmetic stays on small
  #    integers. This is most of the gain (~15x).
  # 2. The 16-word working vector is held in 32 local variables inside
  #    `round/2` rather than a tuple updated with `put_elem/3`, which copies
  #    the whole tuple on every update.
  # 3. The message words are permuted once per call into one schedule per
  #    SIGMA row, so a round reads them with constant `elem/2` indices.

  @mask32 0xFFFFFFFF
  @mask64 0xFFFFFFFFFFFFFFFF

  @iv [
    0x6A09E667F3BCC908,
    0xBB67AE8584CAA73B,
    0x3C6EF372FE94F82B,
    0xA54FF53A5F1D36F1,
    0x510E527FADE682D1,
    0x9B05688C2B3E6C1F,
    0x1F83D9ABFB41BD6B,
    0x5BE0CD19137E2179
  ]

  @sigma [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
  ]

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
  @impl true
  def execute(
        <<rounds::unsigned-big-32, h_bin::binary-size(64), m_bin::binary-size(128),
          t0::unsigned-little-64, t1::unsigned-little-64, f::unsigned-8>>,
        gas_limit
      )
      when f in [0, 1] do
    if rounds > gas_limit do
      {:error, :out_of_gas}
    else
      h = for <<word::unsigned-little-64 <- h_bin>>, do: word
      m = List.to_tuple(for <<word::unsigned-little-64 <- m_bin>>, do: word)
      {:ok, compress(h, m, t0, t1, f == 1, rounds), rounds}
    end
  end

  def execute(_input, _gas_limit), do: {:error, :invalid_input}

  defp compress(h, m, t0, t1, final_block?, rounds) do
    [iv0, iv1, iv2, iv3, iv4, iv5, iv6, iv7] = @iv
    iv6 = if final_block?, do: bxor(iv6, @mask64), else: iv6
    v = h ++ [iv0, iv1, iv2, iv3, bxor(iv4, t0), bxor(iv5, t1), iv6, iv7]

    schedules =
      @sigma
      |> Enum.map(fn row -> row |> Enum.map(&elem(m, &1)) |> to_halves() end)
      |> List.to_tuple()

    v_final = v |> to_halves() |> run_rounds(schedules, rounds, 0) |> from_halves()

    # h'[i] = h[i] ^ v[i] ^ v[i + 8]
    {v_first, v_second} = Enum.split(v_final, 8)

    for {{hi, vi}, vi8} <- Enum.zip(Enum.zip(h, v_first), v_second), into: <<>> do
      <<bxor(hi, bxor(vi, vi8))::unsigned-little-64>>
    end
  end

  # 64-bit words <-> flat tuple of {hi, lo} 32-bit halves.
  defp to_halves(words) do
    words
    |> Enum.flat_map(fn word -> [word >>> 32, word &&& @mask32] end)
    |> List.to_tuple()
  end

  defp from_halves(halves) do
    halves
    |> Tuple.to_list()
    |> Enum.chunk_every(2)
    |> Enum.map(fn [hi, lo] -> hi <<< 32 ||| lo end)
  end

  # Rounds cycle through the 10 SIGMA rows: round i uses row rem(i, 10).
  defp run_rounds(v, _schedules, 0, _row), do: v

  defp run_rounds(v, schedules, rounds, row) do
    next_row = if row == 9, do: 0, else: row + 1
    run_rounds(round(v, elem(schedules, row)), schedules, rounds - 1, next_row)
  end

  # One BLAKE2b round: G on the four columns, then on the four diagonals.
  # `s` holds this round's message words as halves, in the order G consumes them.
  defp round(
         {v0h, v0l, v1h, v1l, v2h, v2l, v3h, v3l, v4h, v4l, v5h, v5l, v6h, v6l, v7h, v7l, v8h,
          v8l, v9h, v9l, v10h, v10l, v11h, v11l, v12h, v12l, v13h, v13l, v14h, v14l, v15h, v15l},
         s
       ) do
    {v0h, v0l, v4h, v4l, v8h, v8l, v12h, v12l} =
      g(v0h, v0l, v4h, v4l, v8h, v8l, v12h, v12l, elem(s, 0), elem(s, 1), elem(s, 2), elem(s, 3))

    {v1h, v1l, v5h, v5l, v9h, v9l, v13h, v13l} =
      g(v1h, v1l, v5h, v5l, v9h, v9l, v13h, v13l, elem(s, 4), elem(s, 5), elem(s, 6), elem(s, 7))

    {v2h, v2l, v6h, v6l, v10h, v10l, v14h, v14l} =
      g(
        v2h,
        v2l,
        v6h,
        v6l,
        v10h,
        v10l,
        v14h,
        v14l,
        elem(s, 8),
        elem(s, 9),
        elem(s, 10),
        elem(s, 11)
      )

    {v3h, v3l, v7h, v7l, v11h, v11l, v15h, v15l} =
      g(
        v3h,
        v3l,
        v7h,
        v7l,
        v11h,
        v11l,
        v15h,
        v15l,
        elem(s, 12),
        elem(s, 13),
        elem(s, 14),
        elem(s, 15)
      )

    {v0h, v0l, v5h, v5l, v10h, v10l, v15h, v15l} =
      g(
        v0h,
        v0l,
        v5h,
        v5l,
        v10h,
        v10l,
        v15h,
        v15l,
        elem(s, 16),
        elem(s, 17),
        elem(s, 18),
        elem(s, 19)
      )

    {v1h, v1l, v6h, v6l, v11h, v11l, v12h, v12l} =
      g(
        v1h,
        v1l,
        v6h,
        v6l,
        v11h,
        v11l,
        v12h,
        v12l,
        elem(s, 20),
        elem(s, 21),
        elem(s, 22),
        elem(s, 23)
      )

    {v2h, v2l, v7h, v7l, v8h, v8l, v13h, v13l} =
      g(
        v2h,
        v2l,
        v7h,
        v7l,
        v8h,
        v8l,
        v13h,
        v13l,
        elem(s, 24),
        elem(s, 25),
        elem(s, 26),
        elem(s, 27)
      )

    {v3h, v3l, v4h, v4l, v9h, v9l, v14h, v14l} =
      g(
        v3h,
        v3l,
        v4h,
        v4l,
        v9h,
        v9l,
        v14h,
        v14l,
        elem(s, 28),
        elem(s, 29),
        elem(s, 30),
        elem(s, 31)
      )

    {v0h, v0l, v1h, v1l, v2h, v2l, v3h, v3l, v4h, v4l, v5h, v5l, v6h, v6l, v7h, v7l, v8h, v8l,
     v9h, v9l, v10h, v10l, v11h, v11l, v12h, v12l, v13h, v13l, v14h, v14l, v15h, v15l}
  end

  # The BLAKE2b mixing function G (RFC 7693 §3.1) on 32-bit halves: every
  # word `w` is passed as `wh` (high 32 bits) and `wl` (low 32 bits).
  #
  # - 64-bit add: add the low halves, then carry bit 32 into the high halves.
  # - rotate right by 32: swap the halves.
  # - rotate right by 24 or 16: each half takes its own top bits shifted down
  #   and the other half's bottom bits shifted up.
  # - rotate right by 63 (left by 1): the same, with the shifts reversed.
  #
  # `th`/`tl` hold the halves of the xor being rotated.
  defp g(ah, al, bh, bl, ch, cl, dh, dl, xh, xl, yh, yl) do
    # a = a + b + x
    lo = al + bl + xl
    ah = ah + bh + xh + (lo >>> 32) &&& @mask32
    al = lo &&& @mask32

    # d = (d ^ a) >>> 32
    {dh, dl} = {bxor(dl, al), bxor(dh, ah)}

    # c = c + d
    lo = cl + dl
    ch = ch + dh + (lo >>> 32) &&& @mask32
    cl = lo &&& @mask32

    # b = (b ^ c) >>> 24
    th = bxor(bh, ch)
    tl = bxor(bl, cl)
    bh = (th >>> 24 ||| tl <<< 8) &&& @mask32
    bl = (tl >>> 24 ||| th <<< 8) &&& @mask32

    # a = a + b + y
    lo = al + bl + yl
    ah = ah + bh + yh + (lo >>> 32) &&& @mask32
    al = lo &&& @mask32

    # d = (d ^ a) >>> 16
    th = bxor(dh, ah)
    tl = bxor(dl, al)
    dh = (th >>> 16 ||| tl <<< 16) &&& @mask32
    dl = (tl >>> 16 ||| th <<< 16) &&& @mask32

    # c = c + d
    lo = cl + dl
    ch = ch + dh + (lo >>> 32) &&& @mask32
    cl = lo &&& @mask32

    # b = (b ^ c) >>> 63, i.e. rotate left by 1
    th = bxor(bh, ch)
    tl = bxor(bl, cl)
    bh = (th <<< 1 ||| tl >>> 31) &&& @mask32
    bl = (tl <<< 1 ||| th >>> 31) &&& @mask32

    {ah, al, bh, bl, ch, cl, dh, dl}
  end
end
