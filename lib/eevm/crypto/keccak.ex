defmodule EEVM.Crypto.Keccak do
  @moduledoc """
  Keccak-256, the hash Ethereum calls `keccak256`, in pure Elixir.

  This is Keccak[r = 1088, c = 512] with the original submission's
  `pad10*1` padding: the first padding byte is `0x01`. SHA3-256 (FIPS 202)
  is the same sponge with `0x06`, so the two give different digests.

  The permutation is Keccak-f[1600] from
  [FIPS 202 §3](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.202.pdf):
  24 rounds of θ, ρ, π, χ and ι over a 5×5 array of 64-bit lanes.

  ## Example

      iex> EEVM.Crypto.Keccak.hash_256("") |> Base.encode16(case: :lower)
      "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
  """

  import Bitwise

  # Performance: this hash sits on the interpreter's hot paths (KECCAK256,
  # CREATE2, trie and state-root hashing), so it avoids bignums and
  # allocation inside the permutation.
  #
  # - BEAM small integers hold 60 bits, so a 64-bit lane would be a heap
  #   bignum. Each lane is two 32-bit halves, `h` (high) and `l` (low), as in
  #   `EEVM.Precompiles.Blake2F`, and rotations mask before shifting left so
  #   no intermediate value exceeds 32 bits.
  # - The 50 halves live in local variables and are passed between rounds as
  #   function arguments, not in a tuple rebuilt by every step. The round
  #   body is generated at compile time from the step definitions below, so
  #   the code mirrors FIPS 202 instead of 170 hand-written lines.

  # Rate in bytes: 1600-bit state minus a 512-bit capacity.
  @rate 136
  @mask 0xFFFFFFFF

  # ι round constants RC[i] (FIPS 202 §3.2.5), as {high, low} halves.
  @round_constants [
                     0x0000000000000001,
                     0x0000000000008082,
                     0x800000000000808A,
                     0x8000000080008000,
                     0x000000000000808B,
                     0x0000000080000001,
                     0x8000000080008081,
                     0x8000000000008009,
                     0x000000000000008A,
                     0x0000000000000088,
                     0x0000000080008009,
                     0x000000008000000A,
                     0x000000008000808B,
                     0x800000000000008B,
                     0x8000000000008089,
                     0x8000000000008003,
                     0x8000000000008002,
                     0x8000000000000080,
                     0x000000000000800A,
                     0x800000008000000A,
                     0x8000000080008081,
                     0x8000000000008080,
                     0x0000000080000001,
                     0x8000000080008008
                   ]
                   |> Enum.map(&{&1 >>> 32, &1 &&& @mask})
                   |> List.to_tuple()

  # ρ rotation offsets r[x, y] (FIPS 202 Table 2): one row per y, then
  # flattened so lane x + 5y is at index x + 5y.
  @rotations List.flatten([
               [0, 1, 62, 28, 27],
               [36, 44, 6, 55, 20],
               [3, 10, 43, 25, 39],
               [41, 45, 15, 21, 8],
               [18, 2, 61, 56, 14]
             ])

  # ── Compile-time code generation ──────────────────────────────────────────
  #
  # Lane i = x + 5y of the state is held in variables h<i> and l<i>. The state
  # travels between blocks as the tuple {l0, h0, l1, h1, ..., l24, h24}, the
  # order its bytes take in a block (lanes are little-endian 64-bit words).

  var = fn name -> Macro.var(name, __MODULE__) end
  lane = fn i -> {var.(:"h#{i}"), var.(:"l#{i}")} end
  index = fn x, y -> Integer.mod(x, 5) + 5 * Integer.mod(y, 5) end

  state =
    Enum.flat_map(0..24, fn i ->
      {h, l} = lane.(i)
      [l, h]
    end)

  xor = fn a, b -> quote(do: bxor(unquote(a), unquote(b))) end

  assign = fn {h, l}, {h_value, l_value} ->
    [quote(do: unquote(h) = unquote(h_value)), quote(do: unquote(l) = unquote(l_value))]
  end

  # Rotate a 64-bit value held as halves {h, l} left by r bits. Rotating by
  # 32 or more swaps the halves first.
  rotate_halves = fn hi, lo, r ->
    quote(
      do:
        (unquote(hi) &&& unquote((1 <<< (32 - r)) - 1)) <<< unquote(r) |||
          unquote(lo) >>> unquote(32 - r)
    )
  end

  rotate = fn
    {h, l}, 0 -> {h, l}
    {h, l}, 32 -> {l, h}
    {h, l}, r when r < 32 -> {rotate_halves.(h, l, r), rotate_halves.(l, h, r)}
    {h, l}, r -> {rotate_halves.(l, h, r - 32), rotate_halves.(h, l, r - 32)}
  end

  # θ: C[x] is the parity of column x, D[x] = C[x-1] xor rot(C[x+1], 1), and
  # every lane in column x is xored with D[x].
  column = fn x -> {var.(:"ch#{x}"), var.(:"cl#{x}")} end
  mix = fn x -> {var.(:"dh#{x}"), var.(:"dl#{x}")} end

  column_parity =
    for x <- 0..4 do
      {hs, ls} = Enum.unzip(for y <- 0..4, do: lane.(index.(x, y)))
      assign.(column.(x), {Enum.reduce(hs, xor), Enum.reduce(ls, xor)})
    end

  column_mix =
    for x <- 0..4 do
      {prev_h, prev_l} = column.(rem(x + 4, 5))
      {rot_h, rot_l} = rotate.(column.(rem(x + 1, 5)), 1)
      assign.(mix.(x), {xor.(prev_h, rot_h), xor.(prev_l, rot_l)})
    end

  apply_mix =
    for y <- 0..4, x <- 0..4 do
      {h, l} = lane.(index.(x, y))
      {mix_h, mix_l} = mix.(x)
      assign.({h, l}, {xor.(h, mix_h), xor.(l, mix_l)})
    end

  theta = [column_parity, column_mix, apply_mix]

  # ρ and π: B[y, 2x + 3y] = rot(A[x, y], r[x, y]).
  moved = fn i -> {var.(:"bh#{i}"), var.(:"bl#{i}")} end

  rho_pi =
    for y <- 0..4, x <- 0..4 do
      assign.(
        moved.(index.(y, 2 * x + 3 * y)),
        rotate.(lane.(index.(x, y)), Enum.at(@rotations, index.(x, y)))
      )
    end

  # χ: A[x, y] = B[x, y] xor (not B[x+1, y] and B[x+2, y]).
  chi =
    for y <- 0..4, x <- 0..4 do
      {bh, bl} = moved.(index.(x, y))
      {nh, nl} = moved.(index.(x + 1, y))
      {fh, fl} = moved.(index.(x + 2, y))

      assign.(
        lane.(index.(x, y)),
        {xor.(bh, quote(do: bnot(unquote(nh)) &&& unquote(fh))),
         xor.(bl, quote(do: bnot(unquote(nl)) &&& unquote(fl)))}
      )
    end

  # ι: A[0, 0] xor RC[round].
  {h0, l0} = lane.(0)
  round = var.(:round)

  iota =
    [quote(do: {rc_h, rc_l} = elem(@round_constants, unquote(round)))] ++
      assign.({h0, l0}, {xor.(h0, quote(do: rc_h)), xor.(l0, quote(do: rc_l))})

  round_body = List.flatten([theta, rho_pi, chi, iota])

  # ── Sponge ────────────────────────────────────────────────────────────────

  @doc """
  Returns the 32-byte Keccak-256 digest of `message`.

  ## Example

      iex> EEVM.Crypto.Keccak.hash_256("abc") |> Base.encode16(case: :lower)
      "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
  """
  @spec hash_256(binary()) :: <<_::256>>
  def hash_256(message) when is_binary(message), do: absorb(message, Tuple.duplicate(0, 50))

  # Full blocks are read in place; only the tail is copied to pad it.
  defp absorb(<<block::binary-size(@rate), rest::binary>>, state),
    do: absorb(rest, absorb_block(state, block))

  defp absorb(tail, state), do: state |> absorb_block(pad(tail)) |> squeeze()

  # pad10*1 with Keccak's 0x01 first byte; one byte of room gives 0x81.
  defp pad(tail) when byte_size(tail) == @rate - 1, do: <<tail::binary, 0x81>>
  defp pad(tail), do: <<tail::binary, 0x01, 0::size(@rate - 2 - byte_size(tail))-unit(8), 0x80>>

  # The first 34 halves (17 lanes) are xored with the block, then permuted.
  block_words = for i <- 0..33, do: var.(:"w#{i}")
  block_pattern = Enum.map(block_words, &quote(do: unquote(&1) :: little - 32))
  {rate_halves, capacity_halves} = Enum.split(state, 34)
  absorbed = Enum.zip_with(rate_halves, block_words, xor) ++ capacity_halves

  defp absorb_block({unquote_splicing(state)}, <<unquote_splicing(block_pattern)>>),
    do: permute(unquote_splicing(absorbed), 0)

  defp squeeze(
         {l0, h0, l1, h1, l2, h2, l3, h3, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _,
          _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _}
       ),
       do:
         <<l0::little-32, h0::little-32, l1::little-32, h1::little-32, l2::little-32,
           h2::little-32, l3::little-32, h3::little-32>>

  # Keccak-f[1600]: 24 rounds.
  defp permute(unquote_splicing(state), 24), do: {unquote_splicing(state)}

  defp permute(unquote_splicing(state), unquote(round)) do
    unquote_splicing(round_body)
    permute(unquote_splicing(state), unquote(round) + 1)
  end
end
