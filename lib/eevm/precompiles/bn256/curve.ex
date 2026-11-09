defmodule EEVM.Precompiles.BN256.Curve do
  @moduledoc """
  Arithmetic on the BN254 (alt_bn128) curve for the ecAdd, ecMul, and
  ecPairing precompiles (EIP-196, EIP-197): G1 point addition and scalar
  multiplication, G2 curve and subgroup checks, and the optimal ate pairing.

  Field elements are plain integers in `[0, p)`, kept canonical after every
  operation. The extension fields form the usual tower:

  - Fp2 = Fp[i] / (i² + 1), as `{a0, a1}` = a0 + a1·i
  - Fp6 = Fp2[v] / (v³ − ξ) with ξ = 9 + i, as `{c0, c1, c2}`
  - Fp12 = Fp6[w] / (w² − v), as `{c0, c1}`

  G1 is the curve E: y² = x³ + 3 over Fp, of prime order n. G2 lives on the
  D-type sextic twist E': y² = x³ + 3/ξ over Fp2, which maps into E(Fp12) by
  (x, y) ↦ (x·w², y·w³).

  `pairing_check/1` runs one Miller loop shared by every pair over the NAF of
  6u + 2, then a single final exponentiation, and compares the product with 1.
  The structure follows arkworks' `ark-ec` BN model and the final
  exponentiation follows go-ethereum's `crypto/bn256/cloudflare`.
  """

  # Field modulus p, group order n, and the BN parameter u, with
  # p = 36u⁴ + 36u³ + 24u² + 6u + 1 and n = 36u⁴ + 36u³ + 18u² + 6u + 1
  # (u = 0x44E992B44A6909F1).
  @p 21_888_242_871_839_275_222_246_405_745_257_275_088_696_311_157_297_823_662_689_037_894_645_226_208_583
  @n 21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617
  @u 4_965_661_367_192_848_881

  @typedoc "An element of Fp, in `[0, p)`."
  @type fp :: non_neg_integer()
  @typedoc "An element a0 + a1·i of Fp2."
  @type fp2 :: {fp(), fp()}
  @typedoc "An affine G1 point (not the point at infinity)."
  @type g1 :: {fp(), fp()}
  @typedoc "An affine G1 point or the point at infinity."
  @type g1_or_infinity :: g1() | :infinity
  @typedoc "An affine point on the twist E' (not the point at infinity)."
  @type g2 :: {fp2(), fp2()}

  # --- Compile-time constants ---
  #
  # Frobenius and endomorphism coefficients are powers of ξ. They are computed
  # here, when the module compiles, from their definitions instead of being
  # pasted in as opaque literals.

  p = @p
  xi = {9, 1}

  fp2_mul = fn {a0, a1}, {b0, b1} ->
    {Integer.mod(a0 * b0 - a1 * b1, p), Integer.mod(a0 * b1 + a1 * b0, p)}
  end

  fp2_pow = fn base, exponent ->
    exponent
    |> Integer.digits(2)
    |> Enum.reduce({1, 0}, fn bit, acc ->
      acc = fp2_mul.(acc, acc)
      if bit == 1, do: fp2_mul.(acc, base), else: acc
    end)
  end

  # Coefficients for the p^k-power Frobenius on Fp12: v^(p^k) = v·ξ^((p^k−1)/3),
  # v^(2p^k) = v²·ξ^(2(p^k−1)/3), w^(p^k) = w·ξ^((p^k−1)/6), and their products.
  frobenius = fn k ->
    e = div(Integer.pow(p, k) - 1, 6)
    w = fp2_pow.(xi, e)
    v1 = fp2_pow.(xi, 2 * e)
    v2 = fp2_pow.(xi, 4 * e)
    {v1, v2, w, fp2_mul.(v1, w), fp2_mul.(v2, w)}
  end

  @frobenius1 frobenius.(1)
  @frobenius2 frobenius.(2)

  # b' = 3/ξ, the twist's constant (ξ⁻¹ = ξ^(p² − 2)).
  @twist_b fp2_mul.({3, 0}, fp2_pow.(xi, p * p - 2))

  # ψ = untwist ∘ Frobenius ∘ twist on E': ψ(x, y) = (x̄·ξ^((p−1)/3), ȳ·ξ^((p−1)/2)).
  @psi_x fp2_pow.(xi, div(p - 1, 3))
  @psi_y fp2_pow.(xi, div(p - 1, 2))

  # Signed-digit (NAF) expansions, most significant digit first. A NAF has
  # fewer nonzero digits than binary, and each nonzero digit costs a point
  # addition (Miller loop) or an Fp12 multiplication (exponentiation by u).
  # Subtracting is as cheap as adding: −Q is a negated y, and in the
  # cyclotomic subgroup f⁻¹ is the conjugate of f.
  naf = fn value ->
    value
    |> Stream.unfold(fn
      0 -> nil
      x when rem(x, 2) == 0 -> {0, div(x, 2)}
      x -> {2 - rem(x, 4), div(x - (2 - rem(x, 4)), 2)}
    end)
    |> Enum.reverse()
  end

  # The leading digit is 1 in both; the loops start from Q and f, so drop it.
  @ate_loop_naf tl(naf.(6 * @u + 2))
  @u_naf tl(naf.(@u))

  @p_squared @p * @p
  @two_inv div(@p + 1, 2)

  @fp2_zero {0, 0}
  @fp2_one {1, 0}
  @fp6_zero {@fp2_zero, @fp2_zero, @fp2_zero}
  @fp12_one {{@fp2_one, @fp2_zero, @fp2_zero}, @fp6_zero}
  @g2_infinity {@fp2_one, @fp2_one, @fp2_zero}
  @g1_infinity {1, 1, 0}

  # ecMul window: w = 5 keeps a table of 8 odd multiples (P, 3P, ..., 15P), and
  # a width-5 NAF has on average one nonzero digit per 6 bits, so a 254-bit
  # scalar costs about 254 doublings and 42 additions instead of the ~127
  # additions of plain double-and-add. Wider windows save fewer additions than
  # their larger tables cost to build.
  @wnaf_width 5

  # --- Public API ---

  @doc """
  Returns whether the product of e(P, Q) over `pairs` is 1 in GT.

  Each pair is `{g1, g2}`: an affine point of G1 and an affine point of G2,
  both already validated. Pairs with a point at infinity contribute 1, so
  callers leave them out.
  """
  @spec pairing_check([{g1(), g2()}]) :: boolean()
  def pairing_check([]), do: true

  def pairing_check(pairs) do
    pairs |> miller_loop() |> final_exponentiation() == @fp12_one
  end

  @doc "Returns whether `point` lies on E: y² = x³ + 3."
  @spec g1_on_curve?(g1()) :: boolean()
  def g1_on_curve?({x, y}), do: rem(y * y, @p) == rem(x * x * x + 3, @p)

  @doc "Adds two G1 points (ecAdd), both on the curve."
  @spec g1_add(g1_or_infinity(), g1_or_infinity()) :: g1_or_infinity()
  def g1_add(:infinity, q), do: q
  def g1_add(p, :infinity), do: p
  def g1_add(p, q), do: p |> g1_jacobian() |> g1_add_jacobian(g1_jacobian(q)) |> g1_affine()

  @doc """
  Multiplies a G1 point on the curve by a scalar (ecMul).

  E(Fp) has prime order n, so k·P = (k mod n)·P for every point on the curve,
  and the scalar is reduced first. The product uses a width-5 NAF over a table
  of odd multiples of P, all in Jacobian coordinates, with one inversion at
  the end to return an affine point.
  """
  @spec g1_mul(g1_or_infinity(), non_neg_integer()) :: g1_or_infinity()
  def g1_mul(:infinity, _scalar), do: :infinity

  def g1_mul(point, scalar) do
    case rem(scalar, @n) do
      0 -> :infinity
      k -> point |> g1_jacobian() |> g1_mul_wnaf(k) |> g1_affine()
    end
  end

  @doc "Returns whether `point` lies on the twist E': y² = x³ + 3/ξ."
  @spec g2_on_curve?(g2()) :: boolean()
  def g2_on_curve?({x, y}), do: f2_sqr(y) == f2_add(f2_mul(f2_sqr(x), x), @twist_b)

  @doc """
  Returns whether a point on the twist lies in G2, the order-n subgroup.

  EIP-197 requires it; unlike G1, the twist also has points of other orders.
  Instead of computing n·Q (254 doublings), this uses the endomorphism test
  from Dai, Lin, Zhao and Zhou, "Fast subgroup membership testings for G1, G2
  and GT on pairing-friendly curves" (eprint 2022/348, §3 and §5.1), also used
  by gnark-crypto: Q ∈ G2 ⟺ [u + 1]Q + ψ([u]Q) + ψ²([u]Q) = ψ³([2u]Q). That
  needs one 63-bit multiplication by u.

  The test accepts exactly the kernel of a group endomorphism. G2 is in the
  kernel; the rest of the twist group is cyclic of square-free order
  h = 2p − n = 10069 · 5864401 · 1875725156269 · q₄ (q₄ prime), so the test is
  sound if it rejects one point of each of those prime orders. The unit tests
  check exactly that.
  """
  @spec g2_in_subgroup?(g2()) :: boolean()
  def g2_in_subgroup?(point) do
    u_point = g2_mul_u(point)
    psi1 = g2_psi(u_point)
    psi2 = g2_psi(psi1)
    psi3 = g2_psi(psi2)

    lhs = u_point |> g2_add(g2_jacobian(point)) |> g2_add(psi1) |> g2_add(psi2)
    g2_equal?(lhs, g2_double(psi3))
  end

  # --- Miller loop ---

  # One loop for all pairs: f is squared once per digit and every pair's line
  # values are multiplied into the same f, so k pairs cost one set of Fp12
  # squarings and one final exponentiation instead of k.
  defp miller_loop(pairs) do
    states = for {p, {qx, qy} = q} <- pairs, do: {p, {qx, qy, @fp2_one}, q, {qx, f2_neg(qy)}}

    {f, states} =
      Enum.reduce(@ate_loop_naf, {@fp12_one, states}, fn digit, {f, states} ->
        states
        |> Enum.reduce({f12_sqr(f), []}, fn {p, r, q, neg_q}, {f, acc} ->
          {r, line} = double_step(r)
          {r, f} = add_digit(digit, r, ell(f, line, p), p, q, neg_q)
          {f, [{p, r, q, neg_q} | acc]}
        end)
      end)

    # Optimal ate: after [6u + 2]Q, add the lines through π(Q) and −π²(Q),
    # where π is the Frobenius, which ψ realises on the twist.
    Enum.reduce(states, f, fn {p, r, q, _neg_q}, f ->
      q1 = g2_psi_affine(q)
      {q2x, q2y} = g2_psi_affine(q1)
      {r, line} = add_step(r, q1)
      f = ell(f, line, p)
      {_r, line} = add_step(r, {q2x, f2_neg(q2y)})
      ell(f, line, p)
    end)
  end

  defp add_digit(0, r, f, _p, _q, _neg_q), do: {r, f}

  defp add_digit(digit, r, f, p, q, neg_q) do
    {r, line} = add_step(r, if(digit == 1, do: q, else: neg_q))
    {r, ell(f, line, p)}
  end

  # Doubling step with R = (X, Y, Z) in homogeneous projective coordinates
  # (x = X/Z, y = Y/Z), so no step inverts a field element. Returns 2R and the
  # tangent line at R as three Fp2 coefficients. The line is scaled by −2Y,
  # which lies in Fp2 and so vanishes in the final exponentiation; in exchange
  # it needs no division. Formulas: Costello, Lange and Naehrig, "Faster
  # pairing computations on curves with high-degree twists" (eprint 2009/615).
  defp double_step({x, y, z}) do
    a = f2_mul_fp(f2_mul(x, y), @two_inv)
    b = f2_sqr(y)
    c = f2_sqr(z)
    e = f2_mul(@twist_b, f2_add(f2_double(c), c))
    f = f2_add(f2_double(e), e)
    g = f2_mul_fp(f2_add(b, f), @two_inv)
    h = f2_sub(f2_sqr(f2_add(y, z)), f2_add(b, c))
    j = f2_sqr(x)
    e_squared = f2_sqr(e)

    doubled =
      {f2_mul(a, f2_sub(b, f)), f2_sub(f2_sqr(g), f2_add(f2_double(e_squared), e_squared)),
       f2_mul(b, h)}

    {doubled, {f2_neg(h), f2_add(f2_double(j), j), f2_sub(e, b)}}
  end

  # Mixed addition R + Q (Q affine) in homogeneous coordinates, returning the
  # line through R and Q, scaled by (Rx − Qx·Rz) to avoid dividing.
  defp add_step({rx, ry, rz}, {qx, qy}) do
    theta = f2_sub(ry, f2_mul(qy, rz))
    lambda = f2_sub(rx, f2_mul(qx, rz))
    c = f2_sqr(theta)
    d = f2_sqr(lambda)
    e = f2_mul(lambda, d)
    f = f2_mul(rz, c)
    g = f2_mul(rx, d)
    h = f2_sub(f2_add(e, f), f2_double(g))

    sum = {f2_mul(lambda, h), f2_sub(f2_mul(theta, f2_sub(g, h)), f2_mul(e, ry)), f2_mul(rz, e)}
    {sum, {lambda, f2_neg(theta), f2_sub(f2_mul(theta, qx), f2_mul(lambda, qy))}}
  end

  # Evaluates a line at P and multiplies it into f. Through the untwisting map
  # the line is l0·y_P + l1·x_P·w + l2·w³: nonzero only at Fp12 basis
  # positions 0, 3 and 4 (of 1, v, v², w, vw, v²w), so `mul_by_034/4`
  # multiplies by it in about half the work of a full Fp12 product.
  defp ell(f, {l0, l1, l2}, {px, py}), do: mul_by_034(f, f2_mul_fp(l0, py), f2_mul_fp(l1, px), l2)

  # f · (c0 + (c3 + c4·v)·w), Karatsuba over Fp6 with a sparse second factor.
  defp mul_by_034({{x0, x1, x2} = a0, a1}, c0, c3, c4) do
    a = {f2_mul(x0, c0), f2_mul(x1, c0), f2_mul(x2, c0)}
    b = f6_mul_by_01(a1, c3, c4)
    e = f6_mul_by_01(f6_add(a0, a1), f2_add(c0, c3), c4)
    {f6_add(f6_mul_by_v(b), a), f6_sub(e, f6_add(a, b))}
  end

  # --- Final exponentiation: f^((p¹² − 1)/n) ---

  # Splits the exponent as (p⁶ − 1)(p² + 1) · (p⁴ − p² + 1)/n. The first
  # ("easy") part costs a conjugation, one inversion, and a Frobenius, and
  # moves f into the cyclotomic subgroup, where inverses are conjugates and
  # `cyclotomic_sqr/1` applies. The hard part writes (p⁴ − p² + 1)/n in base p
  # with coefficients that are polynomials in u (Devegili, Scott and Dahab,
  # "Implementing cryptographic pairings over Barreto-Naehrig curves", 2007),
  # so it needs three exponentiations by the 63-bit u instead of one by a
  # 762-bit exponent. This is go-ethereum's chain.
  defp final_exponentiation(f) do
    t1 = f12_mul(f12_conj(f), f12_inv(f))
    t1 = f12_mul(t1, f12_frobenius(t1, 2))

    fp1 = f12_frobenius(t1, 1)
    fp2 = f12_frobenius(t1, 2)
    fp3 = f12_frobenius(fp2, 1)

    fu = exp_by_u(t1)
    fu2 = exp_by_u(fu)
    fu3 = exp_by_u(fu2)

    y0 = fp1 |> f12_mul(fp2) |> f12_mul(fp3)
    y1 = f12_conj(t1)
    y2 = f12_frobenius(fu2, 2)
    y3 = f12_conj(f12_frobenius(fu, 1))
    y4 = f12_conj(f12_mul(fu, f12_frobenius(fu2, 1)))
    y5 = f12_conj(fu2)
    y6 = f12_conj(f12_mul(fu3, f12_frobenius(fu3, 1)))

    t0 = y6 |> cyclotomic_sqr() |> f12_mul(y4) |> f12_mul(y5)
    t1 = y3 |> f12_mul(y5) |> f12_mul(t0)
    t0 = f12_mul(t0, y2)
    t1 = t1 |> cyclotomic_sqr() |> f12_mul(t0) |> cyclotomic_sqr()
    t0 = f12_mul(t1, y1)
    t1 = f12_mul(t1, y0)
    t0 |> cyclotomic_sqr() |> f12_mul(t1)
  end

  # f^u for f in the cyclotomic subgroup, over the NAF of u (f⁻¹ = conj(f)).
  defp exp_by_u(f) do
    f_inv = f12_conj(f)

    Enum.reduce(@u_naf, f, fn
      0, acc -> cyclotomic_sqr(acc)
      1, acc -> f12_mul(cyclotomic_sqr(acc), f)
      -1, acc -> f12_mul(cyclotomic_sqr(acc), f_inv)
    end)
  end

  # Squaring in the cyclotomic subgroup (Granger and Scott, "Faster squaring
  # in the cyclotomic subgroup of sixth degree extensions", PKC 2010). There,
  # f is determined by three Fp4 values, so a square takes three Fp4 squarings
  # (six Fp2 squarings) instead of a full Fp12 squaring (about 12 Fp2
  # multiplications). Valid only for f with f^(p⁶+1) = 1; the coordinate
  # names follow arkworks' `Fp12::cyclotomic_square`.
  defp cyclotomic_sqr({{z0, z4, z3}, {z2, z1, z5}}) do
    {t0, t1} = fp4_sqr(z0, z1)
    {t2, t3} = fp4_sqr(z2, z3)
    {t4, t5} = fp4_sqr(z4, z5)
    xi_t5 = f2_mul_xi(t5)

    {
      {
        f2_add(f2_double(f2_sub(t0, z0)), t0),
        f2_add(f2_double(f2_sub(t2, z4)), t2),
        f2_add(f2_double(f2_sub(t4, z3)), t4)
      },
      {
        f2_add(f2_double(f2_add(xi_t5, z2)), xi_t5),
        f2_add(f2_double(f2_add(t1, z1)), t1),
        f2_add(f2_double(f2_add(t3, z5)), t3)
      }
    }
  end

  # (a + b·y)² in Fp4 = Fp2[y]/(y² − ξ) is (a² + ξ·b²) + 2ab·y.
  defp fp4_sqr(a, b) do
    a2 = f2_sqr(a)
    b2 = f2_sqr(b)
    {f2_add(a2, f2_mul_xi(b2)), f2_sub(f2_sub(f2_sqr(f2_add(a, b)), a2), b2)}
  end

  # --- Fp ---

  defp fp_add(a, b) do
    sum = a + b
    if sum >= @p, do: sum - @p, else: sum
  end

  defp fp_sub(a, b) do
    diff = a - b
    if diff < 0, do: diff + @p, else: diff
  end

  defp fp_neg(0), do: 0
  defp fp_neg(a), do: @p - a

  defp fp_inv(a) do
    {1, inverse, _} = Integer.extended_gcd(a, @p)
    Integer.mod(inverse, @p)
  end

  # --- Fp2 = Fp[i]/(i² + 1) ---
  #
  # Products of two canonical elements are below p², so `rem/2` reduces them;
  # where a difference could go negative, adding p² (or p) first keeps it
  # non-negative, which is cheaper than `Integer.mod/2`'s sign handling.

  defp f2_add({a0, a1}, {b0, b1}), do: {fp_add(a0, b0), fp_add(a1, b1)}
  defp f2_sub({a0, a1}, {b0, b1}), do: {fp_sub(a0, b0), fp_sub(a1, b1)}
  defp f2_double(a), do: f2_add(a, a)
  defp f2_neg({a0, a1}), do: {fp_neg(a0), fp_neg(a1)}
  defp f2_conj({a0, a1}), do: {a0, fp_neg(a1)}

  # Karatsuba: three integer products instead of four.
  defp f2_mul({a0, a1}, {b0, b1}) do
    t0 = a0 * b0
    t1 = a1 * b1
    {rem(t0 - t1 + @p_squared, @p), rem((a0 + a1) * (b0 + b1) - t0 - t1, @p)}
  end

  # (a0 + a1·i)² = (a0 + a1)(a0 − a1) + 2·a0·a1·i: two products.
  defp f2_sqr({a0, a1}), do: {rem((a0 + a1) * (a0 - a1 + @p), @p), rem(2 * a0 * a1, @p)}

  defp f2_mul_fp({a0, a1}, s), do: {rem(a0 * s, @p), rem(a1 * s, @p)}

  # (a0 + a1·i)(9 + i) = (9·a0 − a1) + (a0 + 9·a1)·i: no full products.
  defp f2_mul_xi({a0, a1}), do: {rem(9 * a0 - a1 + @p, @p), rem(a0 + 9 * a1, @p)}

  defp f2_inv({a0, a1}) do
    inverse = fp_inv(rem(a0 * a0 + a1 * a1, @p))
    {rem(a0 * inverse, @p), rem(fp_neg(a1) * inverse, @p)}
  end

  # --- Fp6 = Fp2[v]/(v³ − ξ) ---

  defp f6_add({a0, a1, a2}, {b0, b1, b2}), do: {f2_add(a0, b0), f2_add(a1, b1), f2_add(a2, b2)}
  defp f6_sub({a0, a1, a2}, {b0, b1, b2}), do: {f2_sub(a0, b0), f2_sub(a1, b1), f2_sub(a2, b2)}
  defp f6_neg({a0, a1, a2}), do: {f2_neg(a0), f2_neg(a1), f2_neg(a2)}

  # Multiplying by v shifts the coefficients up, and v³ = ξ wraps the top one.
  defp f6_mul_by_v({a0, a1, a2}), do: {f2_mul_xi(a2), a0, a1}

  # Karatsuba over three coefficients: six Fp2 products instead of nine.
  defp f6_mul({a0, a1, a2}, {b0, b1, b2}) do
    t0 = f2_mul(a0, b0)
    t1 = f2_mul(a1, b1)
    t2 = f2_mul(a2, b2)

    {
      f2_add(f2_mul_xi(f2_sub(f2_sub(f2_mul(f2_add(a1, a2), f2_add(b1, b2)), t1), t2)), t0),
      f2_add(f2_sub(f2_sub(f2_mul(f2_add(a0, a1), f2_add(b0, b1)), t0), t1), f2_mul_xi(t2)),
      f2_add(f2_sub(f2_sub(f2_mul(f2_add(a0, a2), f2_add(b0, b2)), t0), t2), t1)
    }
  end

  # a · (b0 + b1·v), for the sparse line factors: five Fp2 products.
  defp f6_mul_by_01({a0, a1, a2}, b0, b1) do
    t0 = f2_mul(a0, b0)
    t1 = f2_mul(a1, b1)

    {
      f2_add(f2_mul_xi(f2_sub(f2_mul(f2_add(a1, a2), b1), t1)), t0),
      f2_sub(f2_sub(f2_mul(f2_add(a0, a1), f2_add(b0, b1)), t0), t1),
      f2_add(f2_sub(f2_mul(f2_add(a0, a2), b0), t0), t1)
    }
  end

  defp f6_inv({a0, a1, a2}) do
    t0 = f2_sub(f2_sqr(a0), f2_mul_xi(f2_mul(a1, a2)))
    t1 = f2_sub(f2_mul_xi(f2_sqr(a2)), f2_mul(a0, a1))
    t2 = f2_sub(f2_sqr(a1), f2_mul(a0, a2))
    norm = f2_add(f2_mul(a0, t0), f2_mul_xi(f2_add(f2_mul(a2, t1), f2_mul(a1, t2))))
    inverse = f2_inv(norm)
    {f2_mul(t0, inverse), f2_mul(t1, inverse), f2_mul(t2, inverse)}
  end

  # --- Fp12 = Fp6[w]/(w² − v) ---

  defp f12_mul({a0, a1}, {b0, b1}) do
    t0 = f6_mul(a0, b0)
    t1 = f6_mul(a1, b1)
    {f6_add(t0, f6_mul_by_v(t1)), f6_sub(f6_sub(f6_mul(f6_add(a0, a1), f6_add(b0, b1)), t0), t1)}
  end

  # (a0 + a1·w)² = (a0 + a1)(a0 + v·a1) − (1 + v)·a0·a1 + 2·a0·a1·w:
  # two Fp6 products instead of three.
  defp f12_sqr({a0, a1}) do
    ab = f6_mul(a0, a1)
    c0 = f6_sub(f6_sub(f6_mul(f6_add(a0, a1), f6_add(a0, f6_mul_by_v(a1))), ab), f6_mul_by_v(ab))
    {c0, f6_add(ab, ab)}
  end

  # The p⁶-power Frobenius, w ↦ −w.
  defp f12_conj({a0, a1}), do: {a0, f6_neg(a1)}

  defp f12_inv({a0, a1}) do
    inverse = f6_inv(f6_sub(f6_mul(a0, a0), f6_mul_by_v(f6_mul(a1, a1))))
    {f6_mul(a0, inverse), f6_neg(f6_mul(a1, inverse))}
  end

  # The p^k-power Frobenius: conjugate each Fp2 coefficient k times and scale
  # it by the matching power of ξ.
  defp f12_frobenius({{a0, a1, a2}, {b0, b1, b2}}, k) do
    {v1, v2, w, v1w, v2w} = frobenius_coefficients(k)
    conj = if k == 2, do: & &1, else: &f2_conj/1

    {
      {conj.(a0), f2_mul(conj.(a1), v1), f2_mul(conj.(a2), v2)},
      {f2_mul(conj.(b0), w), f2_mul(conj.(b1), v1w), f2_mul(conj.(b2), v2w)}
    }
  end

  defp frobenius_coefficients(1), do: @frobenius1
  defp frobenius_coefficients(2), do: @frobenius2

  # --- G1 arithmetic for ecAdd and ecMul ---
  #
  # Jacobian coordinates (x = X/Z², y = Y/Z³) over Fp, so additions and
  # doublings need no inversion; the point at infinity has Z = 0. The formulas
  # are the Fp versions of the G2 ones below.

  defp g1_jacobian({x, y}), do: {x, y, 1}

  defp g1_affine({_x, _y, 0}), do: :infinity

  defp g1_affine({x, y, z}) do
    z_inv = fp_inv(z)
    z_inv2 = rem(z_inv * z_inv, @p)
    {rem(x * z_inv2, @p), rem(y * rem(z_inv2 * z_inv, @p), @p)}
  end

  defp g1_neg({x, y, z}), do: {x, fp_neg(y), z}

  # k·P for 0 < k < n, scanning the width-5 NAF of k from its top digit. A
  # negative digit −d adds −(d·P), which costs nothing extra: negating a point
  # negates Y.
  defp g1_mul_wnaf(point, k) do
    table = g1_odd_multiples(point)
    neg_table = table |> Tuple.to_list() |> Enum.map(&g1_neg/1) |> List.to_tuple()

    k
    |> wnaf()
    |> Enum.reduce(@g1_infinity, fn
      0, acc -> g1_double(acc)
      d, acc when d > 0 -> g1_add_jacobian(g1_double(acc), elem(table, div(d, 2)))
      d, acc -> g1_add_jacobian(g1_double(acc), elem(neg_table, div(-d, 2)))
    end)
  end

  # {P, 3P, 5P, ..., 15P}: the odd multiples a width-5 NAF digit can name,
  # indexed by div(d, 2).
  defp g1_odd_multiples(point) do
    twice = g1_double(point)
    count = Bitwise.bsl(1, @wnaf_width - 2)

    1..(count - 1)//1
    |> Enum.map_reduce(point, fn _, prev ->
      next = g1_add_jacobian(prev, twice)
      {next, next}
    end)
    |> then(fn {rest, _last} -> List.to_tuple([point | rest]) end)
  end

  # Width-w NAF digits of k, most significant first: each digit is 0 or odd
  # with |d| < 2^(w−1), and any w consecutive digits hold at most one nonzero.
  defp wnaf(k) do
    modulus = Bitwise.bsl(1, @wnaf_width)
    half = Bitwise.bsl(1, @wnaf_width - 1)

    k
    |> Stream.unfold(fn
      0 ->
        nil

      x when rem(x, 2) == 0 ->
        {0, div(x, 2)}

      x ->
        d = rem(x, modulus)
        d = if d >= half, do: d - modulus, else: d
        {d, div(x - d, 2)}
    end)
    |> Enum.reverse()
  end

  # "dbl-2009-l" for a = 0. Z3 = 2·Y·Z, so infinity doubles to infinity.
  defp g1_double({x, y, z}) do
    a = rem(x * x, @p)
    b = rem(y * y, @p)
    c = rem(b * b, @p)
    x_plus_b = x + b
    d = Integer.mod(2 * (x_plus_b * x_plus_b - a - c), @p)
    e = 3 * a
    x3 = Integer.mod(e * e - 2 * d, @p)
    y3 = Integer.mod(e * (d - x3) - 8 * c, @p)
    {x3, y3, rem(2 * y * z, @p)}
  end

  # "add-2007-bl", with the infinity, equal, and opposite cases handled.
  defp g1_add_jacobian({_, _, 0}, q), do: q
  defp g1_add_jacobian(p, {_, _, 0}), do: p

  defp g1_add_jacobian({x1, y1, z1} = p, {x2, y2, z2}) do
    z1z1 = rem(z1 * z1, @p)
    z2z2 = rem(z2 * z2, @p)
    u1 = rem(x1 * z2z2, @p)
    u2 = rem(x2 * z1z1, @p)
    s1 = rem(y1 * rem(z2 * z2z2, @p), @p)
    s2 = rem(y2 * rem(z1 * z1z1, @p), @p)

    cond do
      u1 == u2 and s1 == s2 -> g1_double(p)
      u1 == u2 -> @g1_infinity
      true -> g1_add_distinct(z1, z2, z1z1, z2z2, u1, u2, s1, s2)
    end
  end

  defp g1_add_distinct(z1, z2, z1z1, z2z2, u1, u2, s1, s2) do
    h = fp_sub(u2, u1)
    i = rem(4 * h * h, @p)
    j = rem(h * i, @p)
    r = rem(2 * fp_sub(s2, s1), @p)
    v = rem(u1 * i, @p)
    x3 = Integer.mod(r * r - j - 2 * v, @p)
    y3 = Integer.mod(r * (v - x3) - 2 * s1 * j, @p)
    z1_plus_z2 = z1 + z2
    z3 = Integer.mod((z1_plus_z2 * z1_plus_z2 - z1z1 - z2z2) * h, @p)
    {x3, y3, z3}
  end

  # --- G2 arithmetic for the subgroup check ---
  #
  # Jacobian coordinates over Fp2, as for G1 above.

  defp g2_jacobian({x, y}), do: {x, y, @fp2_one}

  defp g2_psi_affine({x, y}), do: {f2_mul(f2_conj(x), @psi_x), f2_mul(f2_conj(y), @psi_y)}

  # Conjugation is a field automorphism, so ψ applies to X, Y and Z directly.
  defp g2_psi({x, y, z}), do: {f2_mul(f2_conj(x), @psi_x), f2_mul(f2_conj(y), @psi_y), f2_conj(z)}

  defp g2_mul_u(point) do
    base = g2_jacobian(point)
    neg_base = g2_neg(base)

    Enum.reduce(@u_naf, base, fn
      0, acc -> g2_double(acc)
      1, acc -> g2_add(g2_double(acc), base)
      -1, acc -> g2_add(g2_double(acc), neg_base)
    end)
  end

  defp g2_neg({x, y, z}), do: {x, f2_neg(y), z}

  # "dbl-2009-l" for a = 0. Z3 = 2·Y·Z, so infinity doubles to infinity.
  defp g2_double({x, y, z}) do
    a = f2_sqr(x)
    b = f2_sqr(y)
    c = f2_sqr(b)
    d = f2_double(f2_sub(f2_sub(f2_sqr(f2_add(x, b)), a), c))
    e = f2_add(f2_double(a), a)
    x3 = f2_sub(f2_sqr(e), f2_double(d))
    y3 = f2_sub(f2_mul(e, f2_sub(d, x3)), f2_double(f2_double(f2_double(c))))
    {x3, y3, f2_double(f2_mul(y, z))}
  end

  # "add-2007-bl", with the infinity, equal, and opposite cases handled.
  defp g2_add({_, _, @fp2_zero}, q), do: q
  defp g2_add(p, {_, _, @fp2_zero}), do: p

  defp g2_add({x1, y1, z1} = p, {x2, y2, z2}) do
    z1z1 = f2_sqr(z1)
    z2z2 = f2_sqr(z2)
    u1 = f2_mul(x1, z2z2)
    u2 = f2_mul(x2, z1z1)
    s1 = f2_mul(f2_mul(y1, z2), z2z2)
    s2 = f2_mul(f2_mul(y2, z1), z1z1)

    cond do
      u1 == u2 and s1 == s2 -> g2_double(p)
      u1 == u2 -> @g2_infinity
      true -> g2_add_distinct(x1, z1, z2, z1z1, z2z2, u1, u2, s1, s2)
    end
  end

  defp g2_add_distinct(_x1, z1, z2, z1z1, z2z2, u1, u2, s1, s2) do
    h = f2_sub(u2, u1)
    i = f2_sqr(f2_double(h))
    j = f2_mul(h, i)
    r = f2_double(f2_sub(s2, s1))
    v = f2_mul(u1, i)
    x3 = f2_sub(f2_sub(f2_sqr(r), j), f2_double(v))
    y3 = f2_sub(f2_mul(r, f2_sub(v, x3)), f2_double(f2_mul(s1, j)))
    z3 = f2_mul(f2_sub(f2_sub(f2_sqr(f2_add(z1, z2)), z1z1), z2z2), h)
    {x3, y3, z3}
  end

  defp g2_equal?({_, _, @fp2_zero}, {_, _, z2}), do: z2 == @fp2_zero
  defp g2_equal?(_p, {_, _, @fp2_zero}), do: false

  defp g2_equal?({x1, y1, z1}, {x2, y2, z2}) do
    z1z1 = f2_sqr(z1)
    z2z2 = f2_sqr(z2)

    f2_mul(x1, z2z2) == f2_mul(x2, z1z1) and
      f2_mul(y1, f2_mul(z2, z2z2)) == f2_mul(y2, f2_mul(z1, z1z1))
  end
end
