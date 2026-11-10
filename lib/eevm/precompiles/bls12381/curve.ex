defmodule EEVM.Precompiles.Bls12381.Curve do
  @moduledoc """
  Arithmetic on the BLS12-381 curve, in pure Elixir, for the EIP-2537
  precompiles (`0x0B`–`0x11`) and the EIP-4844 point-evaluation precompile
  (`0x0A`).

  Field elements are plain integers in `[0, p)`, kept canonical after every
  operation. The extension fields form the usual tower:

  - Fp2 = Fp[u] / (u² + 1), as `{a0, a1}` = a0 + a1·u
  - Fp6 = Fp2[v] / (v³ − ξ) with ξ = 1 + u, as `{c0, c1, c2}`
  - Fp12 = Fp6[w] / (w² − v), as `{c0, c1}`

  G1 is the order-r subgroup of E: y² = x³ + 4 over Fp. G2 is the order-r
  subgroup of the M-type sextic twist E': y² = x³ + 4(1 + u) over Fp2. A G1
  point has integer coordinates and a G2 point Fp2 (tuple) coordinates, and
  every point function here works on both: the field operations underneath
  dispatch on the coordinate type, so the point formulas, scalar
  multiplication, MSM, and map-to-curve are written once.

  Affine points are `{x, y}` or `:infinity`. Internally points are in
  Jacobian coordinates (x = X/Z², y = Y/Z³), so additions need no inversion.

  The structure mirrors `EEVM.Precompiles.BN256.Curve`. The pairing follows
  arkworks' `ark-ec` BLS12 model (M-type twist, x < 0), map-to-curve follows
  RFC 9380, and the subgroup checks are Scott's endomorphism tests.
  """

  import Bitwise

  # Base field modulus p, subgroup order r, and the BLS parameter
  # x = −0xD201000000010000 (p and r are polynomials in x). The code uses |x|
  # and accounts for the sign where it matters.
  @p 0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAB
  @r 0x73EDA753299D7D483339D80809A1D80553BDA402FFFE5BFEFFFFFFFF00000001
  @x_abs 0xD201000000010000

  @typedoc "An element of Fp, in `[0, p)`."
  @type fp :: non_neg_integer()
  @typedoc "An element a0 + a1·u of Fp2."
  @type fp2 :: {fp(), fp()}
  @typedoc "An affine G1 point (on E) or the point at infinity."
  @type g1 :: {fp(), fp()} | :infinity
  @typedoc "An affine G2 point (on the twist E') or the point at infinity."
  @type g2 :: {fp2(), fp2()} | :infinity
  @typedoc "An affine point of either group."
  @type point :: g1() | g2()

  @g1_generator {0x17F1D3A73197D7942695638C4FA9AC0FC3688C4F9774B905A14E3A3F171BAC586C55E83FF97A1AEFFB3AF00ADB22C6BB,
                 0x08B3F481E3AAA0F1A09E30ED741D8AE4FCF5E095D5D00AF600DB18CB2C04B3EDD03CC744A2888AE40CAA232946C5E7E1}

  @g2_generator {{0x024AA2B2F08F0A91260805272DC51051C6E47AD4FA403B02B4510B647AE3D1770BAC0326A805BBEFD48056C8C121BDB8,
                  0x13E02B6052719F607DACD3A088274F65596BD0D09920B61AB5DA61BBDC7F5049334CF11213945D57E5AC7D055D042B7E},
                 {0x0CE5D527727D6E118CC9CDC6DA2E351AADFD9BAA8CBDD3A76D429A695160D12C923AC9CC3BACA289E193548608B82801,
                  0x0606C4A02EA734CC32ACD2B02BC28B99CB3E287E85A763AF267492AB572E99AB3F370D275CEC1DA1AAA9075FF05F79BE}}

  # --- Compile-time constants ---
  #
  # Frobenius, endomorphism, and map-to-curve constants are computed here,
  # when the module compiles, from their definitions instead of being pasted
  # in as opaque literals. Only the RFC 9380 isogeny coefficients are literals.

  p = @p
  xi = {1, 1}

  fp_pow = fn base, exponent ->
    exponent
    |> Integer.digits(2)
    |> Enum.reduce(1, fn bit, acc ->
      acc = rem(acc * acc, p)
      if bit == 1, do: rem(acc * base, p), else: acc
    end)
  end

  fp_inv = fn a -> fp_pow.(a, p - 2) end

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

  fp2_inv = fn {a0, a1} ->
    inverse = fp_inv.(rem(a0 * a0 + a1 * a1, p))
    {rem(a0 * inverse, p), rem((p - a1) * inverse, p)}
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

  # ψ = untwist ∘ Frobenius ∘ twist on E' (RFC 9380, Appendix G.3):
  # ψ(x, y) = (x̄ / ξ^((p−1)/3), ȳ / ξ^((p−1)/2)). On G2 it acts as [x].
  @psi_x fp2_inv.(fp2_pow.(xi, div(p - 1, 3)))
  @psi_y fp2_inv.(fp2_pow.(xi, div(p - 1, 2)))

  # σ(x, y) = (β·x, y) with β a primitive cube root of unity in Fp, i.e. a
  # root of β² + β + 1, so β = (−1 + √−3)/2. σ is an endomorphism of E that
  # acts on G1 as multiplication by −x² for one of the two roots and by
  # x² − 1 for the other; the unit tests pin that this is the −x² one.
  sqrt_minus_3 = fp_pow.(p - 3, div(p + 1, 4))
  @beta rem((sqrt_minus_3 - 1 + p) * div(p + 1, 2), p)

  # Simplified SWU (RFC 9380, §6.6.2 and §8.8) maps onto curves E1' and E2'
  # isogenous to E and E', then the isogenies below map onto E and E'. Each
  # tuple is {A', B', Z, −B'/A', B'/(Z·A')}.
  g1_a =
    0x144698A3B8E9433D693A02C96D4982B0EA985383EE66A8D8E8981AEFD881AC98936F8DA0E0F97F5CF428082D584C1D

  g1_b =
    0x12E2908D11688030018B12E8753EEE3B2016C1F0F24F4070A0B9C14FCEF35EF55A23215A316CEAA5D1CC48E98E172BE0

  g1_a_inv = fp_inv.(g1_a)

  @g1_sswu {g1_a, g1_b, 11, rem((p - g1_b) * g1_a_inv, p),
            rem(g1_b * fp_inv.(rem(11 * g1_a, p)), p)}

  g2_a = {0, 240}
  g2_b = {1012, 1012}
  g2_z = {p - 2, p - 1}
  g2_a_inv = fp2_inv.(g2_a)

  @g2_sswu {g2_a, g2_b, g2_z, fp2_mul.({p - 1012, p - 1012}, g2_a_inv),
            fp2_mul.(g2_b, fp2_inv.(fp2_mul.(g2_z, g2_a)))}

  # Isogeny coefficients from RFC 9380, Appendix E.2 (11-isogeny, G1) and
  # E.3 (3-isogeny, G2), lowest degree first: k_(1,·) for x_num, k_(2,·) for
  # x_den, k_(3,·) for y_num, k_(4,·) for y_den. The denominators are monic.
  @g1_iso_x_num [
    0x11A05F2B1E833340B809101DD99815856B303E88A2D7005FF2627B56CDB4E2C85610C2D5F2E62D6EAEAC1662734649B7,
    0x17294ED3E943AB2F0588BAB22147A81C7C17E75B2F6A8417F565E33C70D1E86B4838F2A6F318C356E834EEF1B3CB83BB,
    0xD54005DB97678EC1D1048C5D10A9A1BCE032473295983E56878E501EC68E25C958C3E3D2A09729FE0179F9DAC9EDCB0,
    0x1778E7166FCC6DB74E0609D307E55412D7F5E4656A8DBF25F1B33289F1B330835336E25CE3107193C5B388641D9B6861,
    0xE99726A3199F4436642B4B3E4118E5499DB995A1257FB3F086EEB65982FAC18985A286F301E77C451154CE9AC8895D9,
    0x1630C3250D7313FF01D1201BF7A74AB5DB3CB17DD952799B9ED3AB9097E68F90A0870D2DCAE73D19CD13C1C66F652983,
    0xD6ED6553FE44D296A3726C38AE652BFB11586264F0F8CE19008E218F9C86B2A8DA25128C1052ECADDD7F225A139ED84,
    0x17B81E7701ABDBE2E8743884D1117E53356DE5AB275B4DB1A682C62EF0F2753339B7C8F8C8F475AF9CCB5618E3F0C88E,
    0x80D3CF1F9A78FC47B90B33563BE990DC43B756CE79F5574A2C596C928C5D1DE4FA295F296B74E956D71986A8497E317,
    0x169B1F8E1BCFA7C42E0C37515D138F22DD2ECB803A0C5C99676314BAF4BB1B7FA3190B2EDC0327797F241067BE390C9E,
    0x10321DA079CE07E272D8EC09D2565B0DFA7DCCDDE6787F96D50AF36003B14866F69B771F8C285DECCA67DF3F1605FB7B,
    0x6E08C248E260E70BD1E962381EDEE3D31D79D7E22C837BC23C0BF1BC24C6B68C24B1B80B64D391FA9C8BA2E8BA2D229
  ]

  @g1_iso_x_den [
    0x8CA8D548CFF19AE18B2E62F4BD3FA6F01D5EF4BA35B48BA9C9588617FC8AC62B558D681BE343DF8993CF9FA40D21B1C,
    0x12561A5DEB559C4348B4711298E536367041E8CA0CF0800C0126C2588C48BF5713DAA8846CB026E9E5C8276EC82B3BFF,
    0xB2962FE57A3225E8137E629BFF2991F6F89416F5A718CD1FCA64E00B11ACEACD6A3D0967C94FEDCFCC239BA5CB83E19,
    0x3425581A58AE2FEC83AAFEF7C40EB545B08243F16B1655154CCA8ABC28D6FD04976D5243EECF5C4130DE8938DC62CD8,
    0x13A8E162022914A80A6F1D5F43E7A07DFFDFC759A12062BB8D6B44E833B306DA9BD29BA81F35781D539D395B3532A21E,
    0xE7355F8E4E667B955390F7F0506C6E9395735E9CE9CAD4D0A43BCEF24B8982F7400D24BC4228F11C02DF9A29F6304A5,
    0x772CAACF16936190F3E0C63E0596721570F5799AF53A1894E2E073062AEDE9CEA73B3538F0DE06CEC2574496EE84A3A,
    0x14A7AC2A9D64A8B230B3F5B074CF01996E7F63C21BCA68A81996E1CDF9822C580FA5B9489D11E2D311F7D99BBDCC5A5E,
    0xA10ECF6ADA54F825E920B3DAFC7A3CCE07F8D1D7161366B74100DA67F39883503826692ABBA43704776EC3A79A1D641,
    0x95FC13AB9E92AD4476D6E3EB3A56680F682B4EE96F7D03776DF533978F31C1593174E4B4B7865002D6384D168ECDD0A
  ]

  @g1_iso_y_num [
    0x90D97C81BA24EE0259D1F094980DCFA11AD138E48A869522B52AF6C956543D3CD0C7AEE9B3BA3C2BE9845719707BB33,
    0x134996A104EE5811D51036D776FB46831223E96C254F383D0F906343EB67AD34D6C56711962FA8BFE097E75A2E41C696,
    0xCC786BAA966E66F4A384C86A3B49942552E2D658A31CE2C344BE4B91400DA7D26D521628B00523B8DFE240C72DE1F6,
    0x1F86376E8981C217898751AD8746757D42AA7B90EEB791C09E4A3EC03251CF9DE405ABA9EC61DECA6355C77B0E5F4CB,
    0x8CC03FDEFE0FF135CAF4FE2A21529C4195536FBE3CE50B879833FD221351ADC2EE7F8DC099040A841B6DAECF2E8FEDB,
    0x16603FCA40634B6A2211E11DB8F0A6A074A7D0D4AFADB7BD76505C3D3AD5544E203F6326C95A807299B23AB13633A5F0,
    0x4AB0B9BCFAC1BBCB2C977D027796B3CE75BB8CA2BE184CB5231413C4D634F3747A87AC2460F415EC961F8855FE9D6F2,
    0x987C8D5333AB86FDE9926BD2CA6C674170A05BFE3BDD81FFD038DA6C26C842642F64550FEDFE935A15E4CA31870FB29,
    0x9FC4018BD96684BE88C9E221E4DA1BB8F3ABD16679DC26C1E8B6E6A1F20CABE69D65201C78607A360370E577BDBA587,
    0xE1BBA7A1186BDB5223ABDE7ADA14A23C42A0CA7915AF6FE06985E7ED1E4D43B9B3F7055DD4EBA6F2BAFAAEBCA731C30,
    0x19713E47937CD1BE0DFD0B8F1D43FB93CD2FCBCB6CAF493FD1183E416389E61031BF3A5CCE3FBAFCE813711AD011C132,
    0x18B46A908F36F6DEB918C143FED2EDCC523559B8AAF0C2462E6BFE7F911F643249D9CDF41B44D606CE07C8A4D0074D8E,
    0xB182CAC101B9399D155096004F53F447AA7B12A3426B08EC02710E807B4633F06C851C1919211F20D4C04F00B971EF8,
    0x245A394AD1ECA9B72FC00AE7BE315DC757B3B080D4C158013E6632D3C40659CC6CF90AD1C232A6442D9D3F5DB980133,
    0x5C129645E44CF1102A159F748C4A3FC5E673D81D7E86568D9AB0F5D396A7CE46BA1049B6579AFB7866B1E715475224B,
    0x15E6BE4E990F03CE4EA50B3B42DF2EB5CB181D8F84965A3957ADD4FA95AF01B2B665027EFEC01C7704B456BE69C8B604
  ]

  @g1_iso_y_den [
    0x16112C4C3A9C98B252181140FAD0EAE9601A6DE578980BE6EEC3232B5BE72E7A07F3688EF60C206D01479253B03663C1,
    0x1962D75C2381201E1A0CBD6C43C348B885C84FF731C4D59CA4A10356F453E01F78A4260763529E3532F6102C2E49A03D,
    0x58DF3306640DA276FAAAE7D6E8EB15778C4855551AE7F310C35A5DD279CD2ECA6757CD636F96F891E2538B53DBF67F2,
    0x16B7D288798E5395F20D23BF89EDB4D1D115C5DBDDBCD30E123DA489E726AF41727364F2C28297ADA8D26D98445F5416,
    0xBE0E079545F43E4B00CC912F8228DDCC6D19C9F0F69BBB0542EDA0FC9DEC916A20B15DC0FD2EDEDDA39142311A5001D,
    0x8D9E5297186DB2D9FB266EAAC783182B70152C65550D881C5ECD87B6F0F5A6449F38DB9DFA9CCE202C6477FAAF9B7AC,
    0x166007C08A99DB2FC3BA8734ACE9824B5EECFDFA8D0CF8EF5DD365BC400A0051D5FA9C01A58B1FB93D1A1399126A775C,
    0x16A3EF08BE3EA7EA03BCDDFABBA6FF6EE5A4375EFA1F4FD7FEB34FD206357132B920F5B00801DEE460EE415A15812ED9,
    0x1866C8ED336C61231A1BE54FD1D74CC4F9FB0CE4C6AF5920ABC5750C4BF39B4852CFE2F7BB9248836B233D9D55535D4A,
    0x167A55CDA70A6E1CEA820597D94A84903216F763E13D87BB5308592E7EA7D4FBC7385EA3D529B35E346EF48BB8913F55,
    0x4D2F259EEA405BD48F010A01AD2911D9C6DD039BB61A6290E591B36E636A5C871A5C29F4F83060400F8B49CBA8F6AA8,
    0xACCBB67481D033FF5852C1E48C50C477F94FF8AEFCE42D28C0F9A88CEA7913516F968986F7EBBEA9684B529E2561092,
    0xAD6B9514C767FE3C3613144B45F1496543346D98ADF02267D5CEEF9A00D9B8693000763E3B90AC11E99B138573345CC,
    0x2660400EB2E4F3B628BDD0D53CD76F2BF565B94E72927C1CB748DF27942480E420517BD8714CC80D1FADC1326ED06F7,
    0xE0FA1D816DDC03E6B24255E0D7819C171C40F65E273B853324EFCD6356CAA205CA2F570F13497804415473A1D634B8F
  ]

  @g2_iso_x_num [
    {0x5C759507E8E333EBB5B7A9A47D7ED8532C52D39FD3A042A88B58423C50AE15D5C2638E343D9C71C6238AAAAAAAA97D6,
     0x5C759507E8E333EBB5B7A9A47D7ED8532C52D39FD3A042A88B58423C50AE15D5C2638E343D9C71C6238AAAAAAAA97D6},
    {0x0,
     0x11560BF17BAA99BC32126FCED787C88F984F87ADF7AE0C7F9A208C6B4F20A4181472AAA9CB8D555526A9FFFFFFFFC71A},
    {0x11560BF17BAA99BC32126FCED787C88F984F87ADF7AE0C7F9A208C6B4F20A4181472AAA9CB8D555526A9FFFFFFFFC71E,
     0x8AB05F8BDD54CDE190937E76BC3E447CC27C3D6FBD7063FCD104635A790520C0A395554E5C6AAAA9354FFFFFFFFE38D},
    {0x171D6541FA38CCFAED6DEA691F5FB614CB14B4E7F4E810AA22D6108F142B85757098E38D0F671C7188E2AAAAAAAA5ED1,
     0x0}
  ]

  @g2_iso_x_den [
    {0x0,
     0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAA63},
    {0xC,
     0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAA9F}
  ]

  @g2_iso_y_num [
    {0x1530477C7AB4113B59A4C18B076D11930F7DA5D4A07F649BF54439D87D27E500FC8C25EBF8C92F6812CFC71C71C6D706,
     0x1530477C7AB4113B59A4C18B076D11930F7DA5D4A07F649BF54439D87D27E500FC8C25EBF8C92F6812CFC71C71C6D706},
    {0x0,
     0x5C759507E8E333EBB5B7A9A47D7ED8532C52D39FD3A042A88B58423C50AE15D5C2638E343D9C71C6238AAAAAAAA97BE},
    {0x11560BF17BAA99BC32126FCED787C88F984F87ADF7AE0C7F9A208C6B4F20A4181472AAA9CB8D555526A9FFFFFFFFC71C,
     0x8AB05F8BDD54CDE190937E76BC3E447CC27C3D6FBD7063FCD104635A790520C0A395554E5C6AAAA9354FFFFFFFFE38F},
    {0x124C9AD43B6CF79BFBF7043DE3811AD0761B0F37A1E26286B0E977C69AA274524E79097A56DC4BD9E1B371C71C718B10,
     0x0}
  ]

  @g2_iso_y_den [
    {0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFA8FB,
     0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFA8FB},
    {0x0,
     0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFA9D3},
    {0x12,
     0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAA99}
  ]

  # Highest degree first, for Horner's rule, with the monic denominators'
  # leading 1 made explicit.
  @g1_iso {Enum.reverse(@g1_iso_x_num), [1 | Enum.reverse(@g1_iso_x_den)],
           Enum.reverse(@g1_iso_y_num), [1 | Enum.reverse(@g1_iso_y_den)]}
  @g2_iso {Enum.reverse(@g2_iso_x_num), [{1, 0} | Enum.reverse(@g2_iso_x_den)],
           Enum.reverse(@g2_iso_y_num), [{1, 0} | Enum.reverse(@g2_iso_y_den)]}

  # Cofactor-clearing scalar for G1 (RFC 9380, §8.8.1): h_eff = 1 − x.
  @g1_h_eff @x_abs + 1

  # Bits of |x| below the leading 1, for the Miller loop and the
  # multiplications by x. |x| has only six set bits, so plain binary is
  # already sparse.
  @x_abs_bits tl(Integer.digits(@x_abs, 2))

  @sqrt_exponent_bits Integer.digits(div(@p + 1, 4), 2)

  @two_inv div(@p + 1, 2)
  @p_squared @p * @p

  @fp2_zero {0, 0}
  @fp2_one {1, 0}
  @fp6_zero {@fp2_zero, @fp2_zero, @fp2_zero}
  @fp12_one {{@fp2_one, @fp2_zero, @fp2_zero}, @fp6_zero}

  @g2_b {4, 4}

  # Scalar multiplication window: a width-5 NAF over a table of 8 odd
  # multiples (P, 3P, ..., 15P) costs about one addition per 6 bits.
  @wnaf_width 5

  # --- Public API ---

  @doc "Returns the base field modulus p."
  @spec fp_modulus() :: pos_integer()
  def fp_modulus, do: @p

  @doc "Returns the standard generator of G1."
  @spec g1_generator() :: g1()
  def g1_generator, do: @g1_generator

  @doc "Returns the standard generator of G2."
  @spec g2_generator() :: g2()
  def g2_generator, do: @g2_generator

  @doc """
  Returns whether an affine point lies on its curve: E (y² = x³ + 4) for a
  G1 point, the twist E' (y² = x³ + 4(1 + u)) for a G2 point.
  """
  @spec on_curve?(point()) :: boolean()
  def on_curve?(:infinity), do: true
  def on_curve?({x, y}) when is_integer(x), do: fp_sqr(y) == fp_add(fp_mul(fp_sqr(x), x), 4)
  def on_curve?({x, y}), do: f2_sqr(y) == f2_add(f2_mul(f2_sqr(x), x), @g2_b)

  @doc """
  Returns whether a point already known to be on its curve lies in the
  order-r subgroup (G1 or G2).

  Instead of computing r·P (255 doublings), this uses Scott's endomorphism
  tests ("A note on group membership tests for G1, G2 and GT on BLS
  pairing-friendly curves", eprint 2021/1130, §6 and §4), whose correctness
  for BLS12-381 is proved in Dai, Lin, Zhao and Zhou, eprint 2022/352:

  - G1: σ(P) = −[x²]P, with σ(x, y) = (β·x, y);
  - G2: ψ(P) = [x]P.

  Each needs one or two multiplications by the 64-bit |x|.
  """
  @spec in_subgroup?(point()) :: boolean()
  def in_subgroup?(:infinity), do: true

  def in_subgroup?({x, y} = point) when is_integer(x) do
    minus_x2_p = point |> jacobian() |> mul_by_x_abs() |> mul_by_x_abs() |> jac_neg()
    jac_equal?(minus_x2_p, {fp_mul(x, @beta), y, 1})
  end

  def in_subgroup?(point) do
    q = jacobian(point)
    jac_equal?(psi(q), mul_by_x(q))
  end

  @doc "Negates an affine point."
  @spec neg(point()) :: point()
  def neg(:infinity), do: :infinity
  def neg({x, y}), do: {x, fe_neg(y)}

  @doc "Adds two affine points of the same group, both on the curve."
  @spec add(point(), point()) :: point()
  def add(:infinity, q), do: q
  def add(p, :infinity), do: p
  def add(p, q), do: p |> jacobian() |> jac_add(jacobian(q)) |> affine()

  @doc """
  Returns the multi-scalar multiplication Σ kᵢ·Pᵢ over `{point, scalar}`
  pairs of one group.

  Every point must be in the order-r subgroup, so each scalar is first
  reduced mod r. A single term uses a width-5 NAF; several use Pippenger's
  bucket method.
  """
  @spec msm([{point(), non_neg_integer()}]) :: point()
  def msm(pairs) do
    terms = for {point, k} <- pairs, point != :infinity, rem(k, @r) != 0, do: {point, rem(k, @r)}

    case terms do
      [] -> :infinity
      [{point, k}] -> point |> jacobian() |> mul(k) |> affine()
      terms -> terms |> pippenger() |> affine()
    end
  end

  @doc """
  Returns whether the product of e(P, Q) over `pairs` is 1 in GT.

  Each pair is `{g1, g2}` of points already checked to be in G1 and G2.
  Pairs with a point at infinity contribute 1. One Miller loop is shared by
  every pair, followed by a single final exponentiation.
  """
  @spec pairing_check([{g1(), g2()}]) :: boolean()
  def pairing_check(pairs) do
    case for({p, q} <- pairs, p != :infinity, q != :infinity, do: {p, q}) do
      [] -> true
      pairs -> pairs |> miller_loop() |> final_exponentiation() == @fp12_one
    end
  end

  @doc """
  Maps an Fp element to a G1 point (EIP-2537 `MAP_FP_TO_G1`): the simplified
  SWU map onto E1', the 11-isogeny to E, and cofactor clearing by
  h_eff = 1 − x (RFC 9380, §6.6.2, §6.6.3 and §8.8.1).
  """
  @spec map_fp_to_g1(fp()) :: g1()
  def map_fp_to_g1(u) do
    {x, y} = sswu(u, @g1_sswu)

    case iso_map(x, y, @g1_iso) do
      :infinity -> :infinity
      point -> point |> jacobian() |> mul(@g1_h_eff) |> affine()
    end
  end

  @doc """
  Maps an Fp2 element to a G2 point (EIP-2537 `MAP_FP2_TO_G2`): the
  simplified SWU map onto E2', the 3-isogeny to E', and cofactor clearing
  with the endomorphism ψ (RFC 9380, §8.8.2 and Appendix G.3).
  """
  @spec map_fp2_to_g2(fp2()) :: g2()
  def map_fp2_to_g2(u) do
    {x, y} = sswu(u, @g2_sswu)

    case iso_map(x, y, @g2_iso) do
      :infinity -> :infinity
      point -> point |> jacobian() |> clear_cofactor_g2() |> affine()
    end
  end

  @doc """
  Decompresses a 48-byte G1 point in the ZCash serialization used by KZG
  commitments and proofs (the consensus specs' `bytes_to_kzg_commitment`).

  The top three bits are flags: compressed (must be set), infinity, and the
  sign that picks the larger of y and p − y. The result is on the curve but
  not checked to be in G1.
  """
  @spec g1_decompress(binary()) :: {:ok, g1()} | :error
  def g1_decompress(<<1::1, 1::1, 0::1, 0::381>>), do: {:ok, :infinity}

  def g1_decompress(<<1::1, 0::1, sign::1, x::381>>) when x < @p do
    case fp_sqrt(fp_add(fp_mul(fp_sqr(x), x), 4)) do
      {:ok, y} -> {:ok, {x, if(y > @p - y == (sign == 1), do: y, else: fp_neg(y))}}
      :error -> :error
    end
  end

  def g1_decompress(_bytes), do: :error

  # --- Scalar multiplication and MSM ---

  # k·P for k > 0, scanning the width-5 NAF of k from its top digit. A
  # negative digit −d adds −(d·P), which costs nothing extra: negating a
  # point negates Y.
  defp mul(point, k) do
    table = odd_multiples(point)
    neg_table = table |> Tuple.to_list() |> Enum.map(&jac_neg/1) |> List.to_tuple()

    k
    |> wnaf()
    |> Enum.reduce(jac_infinity(point), fn
      0, acc -> jac_double(acc)
      d, acc when d > 0 -> jac_add(jac_double(acc), elem(table, div(d, 2)))
      d, acc -> jac_add(jac_double(acc), elem(neg_table, div(-d, 2)))
    end)
  end

  # {P, 3P, 5P, ..., 15P}: the odd multiples a width-5 NAF digit can name,
  # indexed by div(d, 2).
  defp odd_multiples(point) do
    twice = jac_double(point)

    1..(bsl(1, @wnaf_width - 2) - 1)//1
    |> Enum.map_reduce(point, fn _, prev ->
      next = jac_add(prev, twice)
      {next, next}
    end)
    |> then(fn {rest, _last} -> List.to_tuple([point | rest]) end)
  end

  # Width-w NAF digits of k, most significant first: each digit is 0 or odd
  # with |d| < 2^(w−1), and any w consecutive digits hold at most one nonzero.
  defp wnaf(k) do
    modulus = bsl(1, @wnaf_width)
    half = bsl(1, @wnaf_width - 1)

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

  # [|x|]P by double-and-add over the six set bits of |x|.
  defp mul_by_x_abs(point) do
    Enum.reduce(@x_abs_bits, point, fn
      0, acc -> jac_double(acc)
      1, acc -> jac_add(jac_double(acc), point)
    end)
  end

  # [x]P, with x negative.
  defp mul_by_x(point), do: point |> mul_by_x_abs() |> jac_neg()

  # Pippenger's bucket method: split each scalar into c-bit windows; per
  # window, add every point into the bucket named by its digit, and sum the
  # buckets as Σ d·B_d. Each window then costs about n + 2^(c+1) additions
  # instead of n full scalar multiplications sharing nothing.
  defp pippenger([{point, _k} | _] = terms) do
    c = pippenger_window(length(terms))
    mask = bsl(1, c) - 1
    infinity = jac_infinity(jacobian(point))
    terms = for {point, k} <- terms, do: {jacobian(point), k}
    top_window = div(bit_length(@r) - 1, c)

    Enum.reduce(top_window..0//-1, infinity, fn window, acc ->
      shift = window * c

      buckets =
        Enum.reduce(terms, %{}, fn {point, k}, buckets ->
          case band(bsr(k, shift), mask) do
            0 -> buckets
            digit -> Map.update(buckets, digit, point, &jac_add(&1, point))
          end
        end)

      acc |> double_times(c) |> jac_add(bucket_sum(buckets, mask, infinity))
    end)
  end

  # Window widths that minimise windows × (n + 2^(c+1)) for 255-bit scalars.
  defp pippenger_window(n) when n < 4, do: 2
  defp pippenger_window(n) when n < 12, do: 3
  defp pippenger_window(n) when n < 32, do: 4
  defp pippenger_window(n) when n < 96, do: 5
  defp pippenger_window(n) when n < 256, do: 6
  defp pippenger_window(_n), do: 7

  # Σ d·B_d without multiplications: walking d down from the top, a running
  # sum collects B_top + ... + B_d, and adding the running sum at every step
  # counts each B_d exactly d times.
  defp bucket_sum(buckets, mask, infinity) do
    {_running, total} =
      Enum.reduce(mask..1//-1, {infinity, infinity}, fn digit, {running, total} ->
        running =
          case buckets do
            %{^digit => bucket} -> jac_add(running, bucket)
            _ -> running
          end

        {running, jac_add(total, running)}
      end)

    total
  end

  defp double_times(point, 0), do: point
  defp double_times(point, n), do: point |> jac_double() |> double_times(n - 1)

  defp bit_length(n), do: length(Integer.digits(n, 2))

  # --- Map to curve (RFC 9380) ---

  # Simplified SWU (§6.6.2) onto y² = x³ + A·x + B, for Fp or Fp2. x1 is a
  # root candidate; if g(x1) is not a square then g(Z·u²·x1) is, and the
  # sign of y is fixed to match u, so the map is a function of u alone.
  defp sswu(u, {a, b, z, minus_b_over_a, b_over_za}) do
    z_u2 = fe_mul(z, fe_sqr(u))
    tv1 = fe_add(fe_sqr(z_u2), z_u2)

    x1 =
      if fe_zero?(tv1),
        do: b_over_za,
        else: fe_mul(minus_b_over_a, fe_add(fe_one(u), fe_inv(tv1)))

    {x, y} =
      case fe_sqrt(curve_rhs(x1, a, b)) do
        {:ok, y} ->
          {x1, y}

        :error ->
          x2 = fe_mul(z_u2, x1)
          {:ok, y} = fe_sqrt(curve_rhs(x2, a, b))
          {x2, y}
      end

    if sgn0(u) == sgn0(y), do: {x, y}, else: {x, fe_neg(y)}
  end

  defp curve_rhs(x, a, b), do: fe_add(fe_mul(fe_add(fe_sqr(x), a), x), b)

  # The isogeny as rational maps: x = x_num/x_den, y = y'·y_num/y_den, with
  # one inversion shared by both denominators. A zero denominator means the
  # point maps to infinity (RFC 9380, §6.6.3).
  defp iso_map(x, y, {x_num, x_den, y_num, y_den}) do
    xd = horner(x_den, x)
    yd = horner(y_den, x)

    if fe_zero?(xd) or fe_zero?(yd) do
      :infinity
    else
      inverse = fe_inv(fe_mul(xd, yd))

      {fe_mul(horner(x_num, x), fe_mul(inverse, yd)),
       fe_mul(y, fe_mul(horner(y_num, x), fe_mul(inverse, xd)))}
    end
  end

  defp horner([lead | rest], x), do: Enum.reduce(rest, lead, &fe_add(fe_mul(&2, x), &1))

  # sgn0 (RFC 9380, §4.1): the parity of the first nonzero coefficient.
  defp sgn0(a) when is_integer(a), do: band(a, 1)
  defp sgn0({0, a1}), do: band(a1, 1)
  defp sgn0({a0, _a1}), do: band(a0, 1)

  # h_eff·P for G2 with ψ, as RFC 9380, Appendix G.3 (Budroni and Pintore):
  # [x² − x − 1]P + [x − 1]ψ(P) + ψ²(2P), about two multiplications by the
  # 64-bit x instead of one by the 636-bit h_eff.
  defp clear_cofactor_g2(p) do
    t1 = mul_by_x(p)
    t2 = psi(p)
    t3 = p |> jac_double() |> psi() |> psi() |> jac_add(jac_neg(t2))
    t2 = mul_by_x(jac_add(t1, t2))

    t3 |> jac_add(t2) |> jac_add(jac_neg(t1)) |> jac_add(jac_neg(p))
  end

  # Conjugation is a field automorphism, so ψ applies to X, Y and Z directly.
  defp psi({x, y, z}), do: {f2_mul(f2_conj(x), @psi_x), f2_mul(f2_conj(y), @psi_y), f2_conj(z)}

  # --- Jacobian points over Fp or Fp2 ---

  defp jacobian({x, y}), do: {x, y, fe_one(x)}

  defp jac_infinity({x, _y, _z}), do: {fe_one(x), fe_one(x), fe_zero(x)}

  defp affine({x, y, z}) do
    if fe_zero?(z) do
      :infinity
    else
      z_inv = fe_inv(z)
      z_inv2 = fe_sqr(z_inv)
      {fe_mul(x, z_inv2), fe_mul(y, fe_mul(z_inv2, z_inv))}
    end
  end

  defp jac_neg({x, y, z}), do: {x, fe_neg(y), z}

  # "dbl-2009-l" for a = 0. Z3 = 2·Y·Z, so infinity doubles to infinity.
  defp jac_double({x, y, z}) do
    a = fe_sqr(x)
    b = fe_sqr(y)
    c = fe_sqr(b)
    d = fe_double(fe_sub(fe_sub(fe_sqr(fe_add(x, b)), a), c))
    e = fe_add(fe_double(a), a)
    x3 = fe_sub(fe_sqr(e), fe_double(d))
    y3 = fe_sub(fe_mul(e, fe_sub(d, x3)), fe_double(fe_double(fe_double(c))))
    {x3, y3, fe_double(fe_mul(y, z))}
  end

  # "add-2007-bl", with the infinity, equal, and opposite cases handled.
  defp jac_add({x1, y1, z1} = p, {x2, y2, z2} = q) do
    cond do
      fe_zero?(z1) -> q
      fe_zero?(z2) -> p
      true -> jac_add_finite(x1, y1, z1, x2, y2, z2, p)
    end
  end

  defp jac_add_finite(x1, y1, z1, x2, y2, z2, p) do
    z1z1 = fe_sqr(z1)
    z2z2 = fe_sqr(z2)
    u1 = fe_mul(x1, z2z2)
    u2 = fe_mul(x2, z1z1)
    s1 = fe_mul(fe_mul(y1, z2), z2z2)
    s2 = fe_mul(fe_mul(y2, z1), z1z1)

    cond do
      u1 == u2 and s1 == s2 ->
        jac_double(p)

      u1 == u2 ->
        jac_infinity(p)

      true ->
        h = fe_sub(u2, u1)
        i = fe_sqr(fe_double(h))
        j = fe_mul(h, i)
        r = fe_double(fe_sub(s2, s1))
        v = fe_mul(u1, i)
        x3 = fe_sub(fe_sub(fe_sqr(r), j), fe_double(v))
        y3 = fe_sub(fe_mul(r, fe_sub(v, x3)), fe_double(fe_mul(s1, j)))
        z3 = fe_mul(fe_sub(fe_sub(fe_sqr(fe_add(z1, z2)), z1z1), z2z2), h)
        {x3, y3, z3}
    end
  end

  defp jac_equal?({x1, y1, z1}, {x2, y2, z2}) do
    case {fe_zero?(z1), fe_zero?(z2)} do
      {true, true} ->
        true

      {false, false} ->
        z1z1 = fe_sqr(z1)
        z2z2 = fe_sqr(z2)

        fe_mul(x1, z2z2) == fe_mul(x2, z1z1) and
          fe_mul(y1, fe_mul(z2, z2z2)) == fe_mul(y2, fe_mul(z1, z1z1))

      _ ->
        false
    end
  end

  # --- Field elements of either Fp or Fp2 ---
  #
  # The point code above calls these; each dispatches on whether its
  # argument is an Fp integer or an Fp2 tuple. One extra pattern match per
  # operation is negligible next to the 381-bit products underneath.

  defp fe_add(a, b) when is_integer(a), do: fp_add(a, b)
  defp fe_add(a, b), do: f2_add(a, b)

  defp fe_sub(a, b) when is_integer(a), do: fp_sub(a, b)
  defp fe_sub(a, b), do: f2_sub(a, b)

  defp fe_mul(a, b) when is_integer(a), do: fp_mul(a, b)
  defp fe_mul(a, b), do: f2_mul(a, b)

  defp fe_sqr(a) when is_integer(a), do: fp_sqr(a)
  defp fe_sqr(a), do: f2_sqr(a)

  defp fe_double(a), do: fe_add(a, a)

  defp fe_neg(a) when is_integer(a), do: fp_neg(a)
  defp fe_neg(a), do: f2_neg(a)

  defp fe_inv(a) when is_integer(a), do: fp_inv(a)
  defp fe_inv(a), do: f2_inv(a)

  defp fe_sqrt(a) when is_integer(a), do: fp_sqrt(a)
  defp fe_sqrt(a), do: f2_sqrt(a)

  defp fe_zero?(a), do: a == 0 or a == @fp2_zero

  defp fe_zero(a) when is_integer(a), do: 0
  defp fe_zero(_a), do: @fp2_zero

  defp fe_one(a) when is_integer(a), do: 1
  defp fe_one(_a), do: @fp2_one

  # --- Fp ---

  defp fp_add(a, b) do
    sum = a + b
    if sum >= @p, do: sum - @p, else: sum
  end

  defp fp_sub(a, b) do
    diff = a - b
    if diff < 0, do: diff + @p, else: diff
  end

  defp fp_mul(a, b), do: rem(a * b, @p)
  defp fp_sqr(a), do: rem(a * a, @p)

  defp fp_neg(0), do: 0
  defp fp_neg(a), do: @p - a

  defp fp_inv(a) do
    {1, inverse, _} = Integer.extended_gcd(a, @p)
    Integer.mod(inverse, @p)
  end

  # p ≡ 3 (mod 4), so if a is a square, a^((p+1)/4) is a square root of it.
  # Squaring the candidate tells whether a was a square at all.
  defp fp_sqrt(a) do
    root =
      Enum.reduce(@sqrt_exponent_bits, 1, fn
        0, acc -> fp_sqr(acc)
        1, acc -> fp_mul(fp_sqr(acc), a)
      end)

    if fp_sqr(root) == a, do: {:ok, root}, else: :error
  end

  # --- Fp2 = Fp[u]/(u² + 1) ---
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

  # (a0 + a1·u)² = (a0 + a1)(a0 − a1) + 2·a0·a1·u: two products.
  defp f2_sqr({a0, a1}), do: {rem((a0 + a1) * (a0 - a1 + @p), @p), rem(2 * a0 * a1, @p)}

  defp f2_mul_fp({a0, a1}, s), do: {rem(a0 * s, @p), rem(a1 * s, @p)}

  # (a0 + a1·u)(1 + u) = (a0 − a1) + (a0 + a1)·u: no products.
  defp f2_mul_xi({a0, a1}), do: {fp_sub(a0, a1), fp_add(a0, a1)}

  defp f2_inv({a0, a1}) do
    inverse = fp_inv(rem(a0 * a0 + a1 * a1, @p))
    {rem(a0 * inverse, @p), rem(fp_neg(a1) * inverse, @p)}
  end

  # Square root in Fp2 from square roots in Fp (the "complex method", as for
  # p ≡ 3 mod 4 in Adj and Rodríguez-Henríquez, eprint 2012/685, §5.3): for
  # a = a0 + a1·u with norm n² = a0² + a1², a root is x0 + x1·u with
  # x0² = (a0 ± n)/2 and x1 = a1/(2·x0). It costs up to three Fp
  # exponentiations instead of an Fp2 exponentiation (about three times the
  # work per step). The final check rejects non-squares.
  defp f2_sqrt({a0, 0}) do
    case fp_sqrt(a0) do
      {:ok, root} -> {:ok, {root, 0}}
      :error -> with {:ok, root} <- fp_sqrt(fp_neg(a0)), do: {:ok, {0, root}}
    end
  end

  defp f2_sqrt({a0, a1} = a) do
    with {:ok, n} <- fp_sqrt(fp_add(fp_sqr(a0), fp_sqr(a1))),
         {:ok, x0} <- half_root(fp_add(a0, n), fp_sub(a0, n)) do
      root = {x0, fp_mul(a1, fp_inv(fp_add(x0, x0)))}
      if f2_sqr(root) == a, do: {:ok, root}, else: :error
    end
  end

  defp half_root(first, second) do
    case fp_sqrt(fp_mul(first, @two_inv)) do
      {:ok, root} -> {:ok, root}
      :error -> fp_sqrt(fp_mul(second, @two_inv))
    end
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

  # a · (b1·v) = ξ·a2·b1 + a0·b1·v + a1·b1·v²: three Fp2 products.
  defp f6_mul_by_1({a0, a1, a2}, b1),
    do: {f2_mul_xi(f2_mul(a2, b1)), f2_mul(a0, b1), f2_mul(a1, b1)}

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

  # The p⁶-power Frobenius, w ↦ −w. In the cyclotomic subgroup, where the
  # final exponentiation lands, it is also the inverse.
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

  # --- Miller loop ---

  # One loop over the bits of |x| for all pairs: f is squared once per bit
  # and every pair's line values are multiplied into the same f, so k pairs
  # cost one set of Fp12 squarings and one final exponentiation instead of k.
  # Q is kept in homogeneous projective coordinates (x = X/Z, y = Y/Z).
  defp miller_loop(pairs) do
    states = for {p, {qx, qy} = q} <- pairs, do: {p, {qx, qy, @fp2_one}, q}

    {f, _states} =
      Enum.reduce(@x_abs_bits, {@fp12_one, states}, fn bit, {f, states} ->
        Enum.reduce(states, {f12_sqr(f), []}, fn {p, r, q}, {f, acc} ->
          {r, line} = double_step(r)
          f = ell(f, line, p)
          {r, f} = if bit == 1, do: add_line(r, q, f, p), else: {r, f}
          {f, [{p, r, q} | acc]}
        end)
      end)

    # x < 0: the loop computed f for |x|, and f_{−|x|} is its inverse up to
    # factors the final exponentiation removes. After that exponentiation the
    # inverse is the conjugate, so conjugating here is enough.
    f12_conj(f)
  end

  defp add_line(r, q, f, p) do
    {r, line} = add_step(r, q)
    {r, ell(f, line, p)}
  end

  # Doubling step in homogeneous projective coordinates. Returns 2R and the
  # tangent line at R as three Fp2 coefficients, scaled by a factor in Fp2
  # that vanishes in the final exponentiation, so no step divides. Formulas:
  # Costello, Lange and Naehrig, "Faster pairing computations on curves with
  # high-degree twists" (eprint 2009/615), arranged as in arkworks for an
  # M-type twist. b' = 4(1 + u), so b'·3Z² = 12·ξ·Z² needs no full product.
  defp double_step({x, y, z}) do
    a = f2_mul_fp(f2_mul(x, y), @two_inv)
    b = f2_sqr(y)
    c = f2_sqr(z)
    e = f2_mul_xi(f2_mul_fp(c, 12))
    f = f2_add(f2_double(e), e)
    g = f2_mul_fp(f2_add(b, f), @two_inv)
    h = f2_sub(f2_sqr(f2_add(y, z)), f2_add(b, c))
    j = f2_sqr(x)
    e_squared = f2_sqr(e)

    doubled =
      {f2_mul(a, f2_sub(b, f)), f2_sub(f2_sqr(g), f2_add(f2_double(e_squared), e_squared)),
       f2_mul(b, h)}

    {doubled, {f2_sub(e, b), f2_add(f2_double(j), j), f2_neg(h)}}
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
    {sum, {f2_sub(f2_mul(theta, qx), f2_mul(lambda, qy)), f2_neg(theta), lambda}}
  end

  # Evaluates a line at P and multiplies it into f. For an M-type twist the
  # untwisted line is l0 + l1·x_P·v + l2·y_P·v·w: nonzero only at Fp12 basis
  # positions 0, 1 and 4 (of 1, v, v², w, vw, v²w), so `mul_by_014/4`
  # multiplies by it in about half the work of a full Fp12 product.
  defp ell(f, {l0, l1, l2}, {px, py}), do: mul_by_014(f, l0, f2_mul_fp(l1, px), f2_mul_fp(l2, py))

  # f · ((c0 + c1·v) + c4·v·w), Karatsuba over Fp6 with a sparse second factor.
  defp mul_by_014({a0, a1}, c0, c1, c4) do
    aa = f6_mul_by_01(a0, c0, c1)
    bb = f6_mul_by_1(a1, c4)
    e = f6_mul_by_01(f6_add(a0, a1), c0, f2_add(c1, c4))
    {f6_add(f6_mul_by_v(bb), aa), f6_sub(f6_sub(e, aa), bb)}
  end

  # --- Final exponentiation ---

  # f^((p¹² − 1)/r) up to a fixed power coprime to r, which keeps "= 1"
  # exact. The easy part, (p⁶ − 1)(p² + 1), costs a conjugation, an inversion,
  # and a Frobenius, and moves f into the cyclotomic subgroup, where inverses
  # are conjugates and `cyclotomic_sqr/1` applies. The hard part is the
  # addition chain of Hayashida, Hayasaka and Teruya ("Efficient final
  # exponentiation via cyclotomic structure for pairings over families of
  # elliptic curves", eprint 2020/875), as in gnark-crypto and arkworks: five
  # exponentiations by the 64-bit x instead of one by a 1269-bit exponent.
  defp final_exponentiation(f) do
    r = f12_mul(f12_conj(f), f12_inv(f))
    r = f12_mul(f12_frobenius(r, 2), r)

    y0 = cyclotomic_sqr(r)
    y1 = f12_mul(exp_by_x(r), f12_conj(r))
    y2 = exp_by_x(y1)
    y1 = f12_mul(f12_conj(y1), y2)
    y2 = exp_by_x(y1)
    y1 = f12_mul(f12_frobenius(y1, 1), y2)
    r = f12_mul(r, y0)
    y0 = exp_by_x(y1)
    y2 = exp_by_x(y0)
    y0 = f12_frobenius(y1, 2)
    y1 = y1 |> f12_conj() |> f12_mul(y2) |> f12_mul(y0)
    f12_mul(r, y1)
  end

  # f^x for f in the cyclotomic subgroup: f^|x| by square-and-multiply over
  # the six set bits of |x|, then a conjugation for the sign.
  defp exp_by_x(f) do
    @x_abs_bits
    |> Enum.reduce(f, fn
      0, acc -> cyclotomic_sqr(acc)
      1, acc -> f12_mul(cyclotomic_sqr(acc), f)
    end)
    |> f12_conj()
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
end
