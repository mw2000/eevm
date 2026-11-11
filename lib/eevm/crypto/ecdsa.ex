defmodule EEVM.Crypto.ECDSA do
  @moduledoc """
  ECDSA over the short-Weierstrass curves `y² = x³ + ax + b (mod p)` that
  Ethereum uses, in pure Elixir:

  - `:secp256k1` for ECRECOVER (`0x01`) and for transaction and EIP-7702
    authorization signatures: public-key recovery (`recover/5`) and
    deterministic signing (`sign/3`).
  - `:p256` (NIST P-256, secp256r1) for P256VERIFY (`0x100`, EIP-7951):
    `verify/5`.

  Both curves share one implementation of
  [SEC 1 v2](https://www.secg.org/sec1-v2.pdf) §4.1. Points are computed in
  Jacobian coordinates `{X, Y, Z}`, which stand for the affine point
  `(X / Z², Y / Z³)`, so adding and doubling need no field inversion; the
  point at infinity is `:infinity`. Scalar multiplication recodes scalars in
  width-w NAF, so about one bit in six or nine costs an addition. Each base
  point gets a table of its odd multiples; the base point `G`'s table is wide
  and built at compile time. `u₁·G + u₂·Q` shares one chain of doublings
  between both products (Shamir's trick). On secp256k1 the GLV endomorphism
  splits each scalar into two halves of about 128 bits, which halves the
  doublings.

  Hashes and private keys are 32-byte big-endian binaries; `r`, `s` and
  coordinates are integers.

  This code is not constant-time. eevm verifies and recovers public
  signatures; `sign/3` serves tests, tooling and examples, not keys that
  must resist timing side channels.
  """

  import Bitwise

  @compile {:inline, mod: 2}

  alias EEVM.Crypto.SHA256

  @typedoc "A supported curve."
  @type curve :: :secp256k1 | :p256

  @typedoc "An affine point `{x, y}`."
  @type point :: {non_neg_integer(), non_neg_integer()}

  curves = %{
    # SEC 2 v2 §2.4.1.
    secp256k1: %{
      p: 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F,
      a: 0,
      b: 7,
      n: 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141,
      g:
        {0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
         0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8},
      # φ(x, y) = (β·x, y) maps every point P to λ·P, where β³ ≡ 1 (mod p) and
      # λ = 0x5363AD4CC05C30E0A5261C028812645A122E22EA20816678DF02967C1B23BD72
      # with λ³ ≡ 1 (mod n). The basis vectors (a, b) are short solutions of
      # a + b·λ ≡ 0 (mod n). Constants from libsecp256k1 and Guide to Elliptic
      # Curve Cryptography (Hankerson, Menezes, Vanstone), Example 3.73.
      endomorphism: %{
        beta: 0x7AE96A2B657C07106E64479EAC3434E99CF0497512F58995C1396C28719501EE,
        basis:
          {{0x3086D221A7D46BCDE86C90E49284EB15, -0xE4437ED6010E88286F547FA90ABFE4C3},
           {0x114CA50F7A8E2F3F657C1108D9D44CFD8, 0x3086D221A7D46BCDE86C90E49284EB15}}
      }
    },
    # NIST SP 800-186 §3.2.1.3.
    p256: %{
      p: 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF,
      # a = p - 3, kept as -3 for the cheaper doubling in `tangent/3`.
      a: -3,
      b: 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B,
      n: 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551,
      g:
        {0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
         0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5},
      endomorphism: nil
    }
  }

  # wNAF window widths (see `wnaf/2`). The base point's table is built once,
  # at compile time, so it can be wide: 64 entries, one addition per 9 scalar
  # bits on average. Any other point's table is built on every call (a
  # doubling and 7 additions), and 5 bits, one addition per 6 bits, costs
  # least overall.
  @generator_window 8
  @point_window 5

  # The base point's odd multiples G, 3G, …, 127G (and their images under φ,
  # for secp256k1) as Jacobian points with Z = 1, which `add/3` adds with the
  # cheaper mixed formula. Plain affine arithmetic, with an inversion per
  # step, is fine at compile time; none of these multiples is the point at
  # infinity, so it needs no special cases.
  affine_add = fn {x1, y1} = p1, {x2, y2} = p2, %{p: p, a: a} ->
    {numerator, denominator} =
      if p1 == p2, do: {3 * x1 * x1 + a, 2 * y1}, else: {y2 - y1, x2 - x1}

    {1, inverse, _} = Integer.extended_gcd(Integer.mod(denominator, p), p)
    slope = Integer.mod(numerator * inverse, p)
    x3 = Integer.mod(slope * slope - x1 - x2, p)
    {x3, Integer.mod(slope * (x1 - x3) - y1, p)}
  end

  generator_tables = fn %{p: p, g: g, endomorphism: endomorphism} = curve ->
    twice = affine_add.(g, g, curve)

    others =
      Enum.scan(2..(1 <<< (@generator_window - 2)), g, fn _i, previous ->
        affine_add.(previous, twice, curve)
      end)

    table = for {x, y} <- [g | others], do: {x, y, 1}

    case endomorphism do
      nil ->
        [List.to_tuple(table)]

      %{beta: beta} ->
        [
          List.to_tuple(table),
          List.to_tuple(for {x, y, 1} <- table, do: {rem(beta * x, p), y, 1})
        ]
    end
  end

  @curves Map.new(curves, fn {name, curve} ->
            {name, Map.put(curve, :generator_tables, generator_tables.(curve))}
          end)

  @doc """
  Returns the order `n` of `curve`'s base point.

  ## Example

      iex> EEVM.Crypto.ECDSA.order(:secp256k1)
      0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  """
  @spec order(curve()) :: pos_integer()
  def order(curve), do: @curves[curve].n

  @doc """
  Returns the public key `d·G` of the 32-byte private key `d`, or
  `{:error, :invalid_private_key}` unless `0 < d < n`.

  ## Example

      iex> {:ok, {x, _y}} = EEVM.Crypto.ECDSA.public_key(:secp256k1, <<1::256>>)
      iex> x == 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
      true
  """
  @spec public_key(curve(), <<_::256>>) :: {:ok, point()} | {:error, :invalid_private_key}
  def public_key(curve, <<d::256>>) do
    %{n: n} = params = @curves[curve]

    if d > 0 and d < n,
      do: {:ok, [{d, :generator}] |> linear_combination(params) |> to_affine(params)},
      else: {:error, :invalid_private_key}
  end

  @doc """
  Recovers the public key that produced the signature `(r, s)` over the
  32-byte `hash` (SEC 1 §4.1.6).

  `recovery_id` picks the ephemeral point `R`: bit 0 is the parity of its
  `y`, and bit 1 says its `x` is `r + n` rather than `r`. Any `s` in
  `[1, n)` is accepted; enforcing EIP-2's low `s` is the caller's job.

  Returns `{:error, :invalid_signature}` when `r` or `s` is out of range,
  no curve point has that `x`, or the result is the point at infinity.
  """
  @spec recover(curve(), <<_::256>>, non_neg_integer(), non_neg_integer(), 0..3) ::
          {:ok, point()} | {:error, :invalid_signature}
  def recover(curve, <<e::256>>, r, s, recovery_id) when recovery_id in 0..3 do
    %{p: p, n: n} = params = @curves[curve]
    x = r + (recovery_id >>> 1) * n

    with true <- r > 0 and r < n and s > 0 and s < n and x < p,
         {:ok, y} <- y_with_parity(x, recovery_id &&& 1, params) do
      # Q = r⁻¹·(s·R − e·G)
      r_inverse = inverse(r, n)

      [{mod(-e * r_inverse, n), :generator}, {rem(s * r_inverse, n), {x, y}}]
      |> linear_combination(params)
      |> to_affine(params)
      |> case do
        :infinity -> {:error, :invalid_signature}
        point -> {:ok, point}
      end
    else
      _ -> {:error, :invalid_signature}
    end
  end

  @doc """
  Verifies the signature `(r, s)` over the 32-byte `hash` against
  `public_key` (SEC 1 §4.1.4).

  False when `r` or `s` is outside `(0, n)`, `public_key` is not on the
  curve (which rules out `(0, 0)`), or `R' = u₁·G + u₂·Q` is the point at
  infinity; otherwise true when `R'.x mod n == r`. This matches EIP-7951.
  """
  @spec verify(curve(), <<_::256>>, non_neg_integer(), non_neg_integer(), point()) :: boolean()
  def verify(curve, <<e::256>>, r, s, public_key) do
    %{n: n} = params = @curves[curve]

    if r > 0 and r < n and s > 0 and s < n and on_curve?(public_key, params) do
      s_inverse = inverse(s, n)

      case [{rem(e * s_inverse, n), :generator}, {rem(r * s_inverse, n), public_key}]
           |> linear_combination(params)
           |> to_affine(params) do
        :infinity -> false
        {x, _y} -> rem(x, n) == r
      end
    else
      false
    end
  end

  @doc """
  Signs the 32-byte `hash` with the 32-byte `private_key`.

  The nonce is deterministic (RFC 6979 with HMAC-SHA256), and `s` is
  normalised to the low half of `[1, n)` (EIP-2), flipping the recovery id
  to match, as libsecp256k1 does. Returns `{:ok, {r, s, recovery_id}}`, or
  `{:error, :invalid_private_key}` unless `0 < d < n`.
  """
  @spec sign(curve(), <<_::256>>, <<_::256>>) ::
          {:ok, {pos_integer(), pos_integer(), 0..3}} | {:error, :invalid_private_key}
  def sign(curve, <<e::256>> = hash, <<d::256>> = private_key) do
    %{n: n} = params = @curves[curve]

    if d > 0 and d < n do
      signature =
        hash
        |> rfc6979_nonces(private_key, n)
        |> Enum.find_value(&(&1 > 0 and &1 < n and sign_with_nonce(&1, e, d, params)))

      {:ok, signature}
    else
      {:error, :invalid_private_key}
    end
  end

  # SEC 1 §4.1.3: R = k·G, r = R.x mod n, s = k⁻¹·(e + r·d) mod n. Returns
  # false when r or s is zero, so the caller moves on to the next nonce.
  defp sign_with_nonce(k, e, d, %{n: n} = params) do
    {x, y} = [{k, :generator}] |> linear_combination(params) |> to_affine(params)
    r = rem(x, n)
    s = rem(inverse(k, n) * (e + r * d), n)
    recovery_id = (y &&& 1) ||| if(x >= n, do: 2, else: 0)

    cond do
      r == 0 or s == 0 -> false
      s > n >>> 1 -> {r, n - s, bxor(recovery_id, 1)}
      true -> {r, s, recovery_id}
    end
  end

  # RFC 6979 §3.2 with HMAC-SHA256 and a 256-bit order: the stream of
  # candidate nonces, steps (b) through (h).
  defp rfc6979_nonces(<<e::256>>, private_key, n) do
    seed = private_key <> <<rem(e, n)::256>>
    v = :binary.copy(<<1>>, 32)
    k = hmac(<<0::256>>, v <> <<0>> <> seed)
    v = hmac(k, v)
    k = hmac(k, v <> <<1>> <> seed)
    v = hmac(k, v)

    Stream.unfold({k, v}, fn {k, v} ->
      v = hmac(k, v)
      <<candidate::256>> = v
      next_k = hmac(k, v <> <<0>>)
      {candidate, {next_k, hmac(next_k, v)}}
    end)
  end

  # HMAC (RFC 2104) over SHA-256, for keys of at most one 64-byte block.
  defp hmac(key, message) do
    key = key <> <<0::size(64 - byte_size(key))-unit(8)>>
    inner = SHA256.hash(xor_key(key, 0x36) <> message)
    SHA256.hash(xor_key(key, 0x5C) <> inner)
  end

  defp xor_key(key, pad), do: for(<<byte <- key>>, into: <<>>, do: <<bxor(byte, pad)>>)

  # ── Field and curve arithmetic ────────────────────────────────────────────

  defp on_curve?({x, y}, %{p: p, a: a, b: b}) when x < p and y < p,
    do: rem(y * y, p) == mod(x * x * x + a * x + b, p)

  defp on_curve?(_point, _params), do: false

  # Both curves have p ≡ 3 (mod 4), so a square root of c is c^((p+1)/4).
  # Returns the root with the requested parity, if x is on the curve.
  defp y_with_parity(x, parity, %{p: p, a: a, b: b}) do
    y_squared = mod(x * x * x + a * x + b, p)
    y = pow_mod(y_squared, (p + 1) >>> 2, p)

    cond do
      rem(y * y, p) != y_squared -> :error
      (y &&& 1) == parity -> {:ok, y}
      y == 0 -> :error
      true -> {:ok, p - y}
    end
  end

  # base^exponent mod m with a fixed 4-bit window over a 256-bit exponent:
  # 256 squarings and at most 64 multiplications by a power from the table.
  # Square-and-multiply needs one multiplication per set bit instead, about
  # 250 for the nearly all-ones exponent (p + 1) / 4 of a square root.
  defp pow_mod(base, exponent, m) do
    powers = base |> Stream.iterate(&rem(&1 * base, m)) |> Enum.take(15)
    powers = List.to_tuple([1 | powers])

    for <<(digit::4 <- <<exponent::256>>)>>, reduce: 1 do
      result ->
        result = result |> square(m) |> square(m) |> square(m) |> square(m)
        if digit == 0, do: result, else: rem(result * elem(powers, digit), m)
    end
  end

  defp square(x, m), do: rem(x * x, m)

  # The non-negative remainder; differences of field elements can be negative.
  defp mod(x, m) do
    r = rem(x, m)
    if r < 0, do: r + m, else: r
  end

  defp inverse(a, m) do
    {1, x, _y} = Integer.extended_gcd(a, m)
    mod(x, m)
  end

  # Σ kᵢ·Bᵢ, where each base Bᵢ is :generator or an affine point. Each product
  # becomes one or two (GLV, see `split/2`) scalars, each recoded into sparse
  # signed digits (`wnaf/2`) that index a table of the base's odd multiples.
  # All products share one chain of doublings (Shamir's trick, interleaved
  # over any number of products): going down from the most significant
  # position, the sum is doubled once per bit and each digit adds its
  # multiple where it sits. For secp256k1 recovery that is about 130
  # doublings, not 2 × 256, and about 70 additions.
  defp linear_combination(terms, params) do
    additions =
      terms
      |> Enum.flat_map(&additions(&1, params))
      |> List.keysort(0, :desc)

    top = additions |> List.first({0, 0, nil}) |> elem(0)

    {sum, bottom} =
      Enum.reduce(additions, {:infinity, top}, fn {position, digit, table}, {sum, previous} ->
        sum = double_times(sum, previous - position, params)
        {add_digit(sum, digit, table, params), position}
      end)

    double_times(sum, bottom, params)
  end

  # {position, digit, table} for every nonzero digit of the product k·B.
  defp additions({k, base}, params) do
    {window, tables} = base_tables(base, params)

    k
    |> split(params)
    |> Enum.zip(tables)
    |> Enum.flat_map(fn {k, table} ->
      for {position, digit} <- wnaf(k, window), do: {position, digit, table}
    end)
  end

  defp double_times(point, 0, _params), do: point

  defp double_times(point, times, params),
    do: double_times(double(point, params), times - 1, params)

  defp base_tables(:generator, %{generator_tables: tables}), do: {@generator_window, tables}

  defp base_tables({x, y}, params) do
    point = {x, y, 1}
    twice = double(point, params)

    others =
      Enum.scan(2..(1 <<< (@point_window - 2)), point, fn _i, previous ->
        add(twice, previous, params)
      end)

    {@point_window, endomorphism_images(List.to_tuple([point | others]), params)}
  end

  # φ in Jacobian coordinates is (β·X, Y, Z), since x = X / Z².
  defp endomorphism_images(table, %{endomorphism: nil}), do: [table]

  defp endomorphism_images(table, %{p: p, endomorphism: %{beta: beta}}) do
    images = for {x, y, z} <- Tuple.to_list(table), do: {rem(beta * x, p), y, z}
    [table, List.to_tuple(images)]
  end

  # GLV (Gallant, Lambert, Vanstone, CRYPTO 2001; Guide to ECC, Algorithm 3.74).
  # On secp256k1, k·P = k₁·P + k₂·φ(P) whenever k ≡ k₁ + k₂·λ (mod n), and k₁
  # and k₂ can be chosen near 128 bits, so the products need half the
  # doublings. c₁ and c₂ are k's coordinates in the lattice basis, rounded to
  # the nearest integer; each basis vector satisfies a + b·λ ≡ 0, so the
  # congruence holds however they round, and rounding only keeps k₁ and k₂
  # short. They can be negative; `wnaf/2` handles the sign.
  defp split(k, %{endomorphism: nil}), do: [k]

  defp split(k, %{n: n, endomorphism: %{basis: {{a1, b1}, {a2, b2}}}}) do
    c1 = div(2 * b2 * k + n, 2 * n)
    c2 = div(-2 * b1 * k + n, 2 * n)
    [k - c1 * a1 - c2 * a2, -c1 * b1 - c2 * b2]
  end

  # The width-w non-adjacent form of k (Guide to ECC, Algorithm 3.35) as
  # {position, digit} pairs for its nonzero digits, most significant first.
  # Every nonzero digit is odd and below 2^(w−1) in absolute value, and the
  # w − 1 digits above it are zero, so on average one digit in w + 1 costs an
  # addition. The table holds only the 2^(w−2) positive odd multiples; a
  # negative digit adds a negated one, and negating a point is free
  # (y → p − y).
  defp wnaf(k, w) when k < 0, do: for({position, digit} <- wnaf(-k, w), do: {position, -digit})
  defp wnaf(k, w), do: wnaf(k, w, 0, [])

  defp wnaf(0, _w, _position, digits), do: digits

  defp wnaf(k, w, position, digits) when (k &&& 1) == 0,
    do: wnaf(k >>> 1, w, position + 1, digits)

  # The digit is k mod 2^w, centred on zero. Subtracting it leaves a multiple
  # of 2^w, so the next w − 1 digits are zero and can be skipped.
  defp wnaf(k, w, position, digits) do
    digit = k &&& (1 <<< w) - 1
    digit = if digit >= 1 <<< (w - 1), do: digit - (1 <<< w), else: digit
    wnaf((k - digit) >>> w, w, position + w, [{position, digit} | digits])
  end

  # Digit d selects table entry (|d| − 1) / 2, the multiple |d|·B.

  defp add_digit(sum, digit, table, params) when digit > 0,
    do: add(sum, elem(table, digit >>> 1), params)

  defp add_digit(sum, digit, table, %{p: p} = params) do
    {x, y, z} = elem(table, -digit >>> 1)
    add(sum, {x, p - y, z}, params)
  end

  defp to_affine(:infinity, _params), do: :infinity

  defp to_affine({x, y, z}, %{p: p}) do
    z_inverse = inverse(z, p)
    z_inverse_squared = rem(z_inverse * z_inverse, p)
    {rem(x * z_inverse_squared, p), rem(y * z_inverse_squared * z_inverse, p)}
  end

  # Jacobian doubling (EFD dbl-2007-bl):
  # M = 3X² + aZ⁴, S = 4XY², X₃ = M² − 2S, Y₃ = M(S − X₃) − 8Y⁴, Z₃ = 2YZ.
  defp double(:infinity, _params), do: :infinity
  defp double({_x, 0, _z}, _params), do: :infinity

  defp double({x, y, z}, %{p: p} = params) do
    y_squared = rem(y * y, p)
    s = rem(4 * x * y_squared, p)
    m = tangent(x, z, params)
    x3 = mod(m * m - 2 * s, p)
    y3 = mod(m * (s - x3) - 8 * y_squared * y_squared, p)
    {x3, y3, rem(2 * y * z, p)}
  end

  # M = 3X² + aZ⁴. With a = 0 (secp256k1) the Z term vanishes; with a = −3
  # (P-256) it factors as 3(X − Z²)(X + Z²), one multiplication fewer.
  defp tangent(x, _z, %{a: 0, p: p}), do: rem(3 * x * x, p)

  defp tangent(x, z, %{a: -3, p: p}) do
    z_squared = rem(z * z, p)
    mod(3 * (x - z_squared) * (x + z_squared), p)
  end

  # Jacobian addition (EFD add-2007-bl): with U = X·Z'² and S = Y·Z'³ for
  # each point, H = U₂ − U₁ and R = S₂ − S₁. Equal U means the points are
  # equal (double) or opposite (infinity).
  defp add(:infinity, point, _params), do: point
  defp add(point, :infinity, _params), do: point

  # Mixed addition: a table point with Z = 1 has U₂ = X₂·Z₁² and S₂ = Y₂·Z₁³
  # but needs no powers of its own Z, saving 5 of the 16 multiplications.
  defp add({x1, y1, z1} = point, {x2, y2, 1}, %{p: p} = params) do
    z1_squared = rem(z1 * z1, p)
    add_with({x1, rem(x2 * z1_squared, p)}, {y1, rem(y2 * z1 * z1_squared, p)}, z1, point, params)
  end

  defp add({x1, y1, z1} = point, {x2, y2, z2}, %{p: p} = params) do
    z1_squared = rem(z1 * z1, p)
    z2_squared = rem(z2 * z2, p)
    u = {rem(x1 * z2_squared, p), rem(x2 * z1_squared, p)}
    s = {rem(y1 * z2 * z2_squared, p), rem(y2 * z1 * z1_squared, p)}
    add_with(u, s, z1 * z2, point, params)
  end

  defp add_with({u1, u2}, {s1, s2}, z1_z2, point, %{p: p} = params) do
    cond do
      u1 == u2 and s1 == s2 ->
        double(point, params)

      u1 == u2 ->
        :infinity

      true ->
        h = mod(u2 - u1, p)
        r = mod(s2 - s1, p)
        h_squared = rem(h * h, p)
        h_cubed = rem(h * h_squared, p)
        v = rem(u1 * h_squared, p)
        x3 = mod(r * r - h_cubed - 2 * v, p)
        y3 = mod(r * (v - x3) - s1 * h_cubed, p)
        {x3, y3, rem(h * z1_z2, p)}
    end
  end
end
