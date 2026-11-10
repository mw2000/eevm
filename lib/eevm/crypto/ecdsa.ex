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
  point at infinity is `:infinity`. Scalar multiplication uses a fixed 4-bit
  window, and `u₁·G + u₂·Q` shares one chain of doublings between both
  products (Shamir's trick).

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

  @curves %{
    # SEC 2 v2 §2.4.1.
    secp256k1: %{
      p: 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F,
      a: 0,
      b: 7,
      n: 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141,
      g:
        {0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
         0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8}
    },
    # NIST SP 800-186 §3.2.1.3.
    p256: %{
      p: 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF,
      # a = p - 3, kept as -3 so a·Z⁴ in a doubling is a small multiplication.
      a: -3,
      b: 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B,
      n: 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551,
      g:
        {0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
         0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5}
    }
  }

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
    %{n: n, g: g} = params = @curves[curve]

    if d > 0 and d < n,
      do: {:ok, [{d, g}] |> linear_combination(params) |> to_affine(params)},
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
    %{p: p, n: n, g: g} = params = @curves[curve]
    x = r + (recovery_id >>> 1) * n

    with true <- r > 0 and r < n and s > 0 and s < n and x < p,
         {:ok, y} <- y_with_parity(x, recovery_id &&& 1, params) do
      # Q = r⁻¹·(s·R − e·G)
      r_inverse = inverse(r, n)

      [{mod(-e * r_inverse, n), g}, {rem(s * r_inverse, n), {x, y}}]
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
    %{n: n, g: g} = params = @curves[curve]

    if r > 0 and r < n and s > 0 and s < n and on_curve?(public_key, params) do
      s_inverse = inverse(s, n)

      case [{rem(e * s_inverse, n), g}, {rem(r * s_inverse, n), public_key}]
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
  defp sign_with_nonce(k, e, d, %{n: n, g: g} = params) do
    {x, y} = [{k, g}] |> linear_combination(params) |> to_affine(params)
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

  defp pow_mod(base, exponent, m), do: pow_mod(base, exponent, m, 1)
  defp pow_mod(_base, 0, _m, result), do: result

  defp pow_mod(base, exponent, m, result) do
    result = if (exponent &&& 1) == 1, do: rem(result * base, m), else: result
    pow_mod(rem(base * base, m), exponent >>> 1, m, result)
  end

  # The non-negative remainder; differences of field elements can be negative.
  defp mod(x, m) do
    r = rem(x, m)
    if r < 0, do: r + m, else: r
  end

  defp inverse(a, m) do
    {1, x, _y} = Integer.extended_gcd(a, m)
    mod(x, m)
  end

  # Σ kᵢ·Pᵢ for affine points Pᵢ. Each scalar is read as 64 4-bit digits from
  # the top; every step doubles the sum four times, then adds the multiple of
  # each Pᵢ its digit selects from a table of 0·Pᵢ..15·Pᵢ.
  defp linear_combination(terms, params) do
    tables = Enum.map(terms, fn {_k, point} -> window_table(point, params) end)

    digits =
      terms
      |> Enum.map(fn {k, _point} -> for <<(digit::4 <- <<k::256>>)>>, do: digit end)
      |> Enum.zip()

    Enum.reduce(digits, :infinity, fn step_digits, sum ->
      sum = sum |> double(params) |> double(params) |> double(params) |> double(params)

      step_digits
      |> Tuple.to_list()
      |> Enum.zip_with(tables, &elem(&2, &1))
      |> Enum.reduce(sum, &add(&2, &1, params))
    end)
  end

  defp window_table({x, y}, params) do
    point = {x, y, 1}

    Enum.reduce(2..15, [point, :infinity], fn _i, [previous | _] = multiples ->
      [add(previous, point, params) | multiples]
    end)
    |> Enum.reverse()
    |> List.to_tuple()
  end

  defp to_affine(:infinity, _params), do: :infinity

  defp to_affine({x, y, z}, %{p: p}) do
    z_inverse = inverse(z, p)
    z_inverse_squared = rem(z_inverse * z_inverse, p)
    {rem(x * z_inverse_squared, p), rem(y * z_inverse_squared * z_inverse, p)}
  end

  # Jacobian doubling for any a (EFD dbl-2007-bl):
  # M = 3X² + aZ⁴, S = 4XY², X₃ = M² − 2S, Y₃ = M(S − X₃) − 8Y⁴, Z₃ = 2YZ.
  defp double(:infinity, _params), do: :infinity
  defp double({_x, 0, _z}, _params), do: :infinity

  defp double({x, y, z}, %{p: p, a: a}) do
    y_squared = rem(y * y, p)
    s = rem(4 * x * y_squared, p)
    m = mod(3 * x * x + a_z4(a, z, p), p)
    x3 = mod(m * m - 2 * s, p)
    y3 = mod(m * (s - x3) - 8 * y_squared * y_squared, p)
    {x3, y3, rem(2 * y * z, p)}
  end

  defp a_z4(0, _z, _p), do: 0

  defp a_z4(a, z, p) do
    z_squared = rem(z * z, p)
    a * rem(z_squared * z_squared, p)
  end

  # Jacobian addition (EFD add-2007-bl): with U = X·Z'² and S = Y·Z'³ for
  # each point, H = U₂ − U₁ and R = S₂ − S₁. Equal U means the points are
  # equal (double) or opposite (infinity).
  defp add(:infinity, point, _params), do: point
  defp add(point, :infinity, _params), do: point

  defp add({x1, y1, z1} = point, {x2, y2, z2}, %{p: p} = params) do
    z1_squared = rem(z1 * z1, p)
    z2_squared = rem(z2 * z2, p)
    u1 = rem(x1 * z2_squared, p)
    u2 = rem(x2 * z1_squared, p)
    s1 = rem(y1 * z2 * z2_squared, p)
    s2 = rem(y2 * z1 * z1_squared, p)

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
        {x3, y3, rem(h * z1 * z2, p)}
    end
  end
end
