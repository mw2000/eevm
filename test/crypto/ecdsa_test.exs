defmodule EEVM.Crypto.ECDSATest do
  use ExUnit.Case, async: true

  import Bitwise

  alias EEVM.Crypto.{ECDSA, Keccak, SHA256}

  doctest ECDSA

  @p256_n ECDSA.order(:p256)

  # RFC 6979 Appendix A.2.5: NIST P-256, deterministic nonces with HMAC-SHA256.
  @p256_key <<0xC9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721::256>>
  @p256_public {0x60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6,
                0x7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299}

  describe "RFC 6979 A.2.5 (P-256, SHA-256)" do
    test "derives the public key" do
      assert ECDSA.public_key(:p256, @p256_key) == {:ok, @p256_public}
    end

    test ~s(signs "sample"; the RFC's high s comes back as n - s) do
      r = 0xEFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716
      s = 0xF7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8
      hash = SHA256.hash("sample")

      assert {:ok, {^r, low_s, _recovery_id}} = ECDSA.sign(:p256, hash, @p256_key)
      assert low_s == @p256_n - s
      assert ECDSA.verify(:p256, hash, r, s, @p256_public)
      assert ECDSA.verify(:p256, hash, r, low_s, @p256_public)
    end

    test ~s(signs "test") do
      r = 0xF1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367
      s = 0x019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083
      hash = SHA256.hash("test")

      assert {:ok, {^r, ^s, _recovery_id}} = ECDSA.sign(:p256, hash, @p256_key)
      assert ECDSA.verify(:p256, hash, r, s, @p256_public)
      refute ECDSA.verify(:p256, SHA256.hash("sample"), r, s, @p256_public)
    end
  end

  # EIP-155's worked example: private key 0x4646...46, chain ID 1. Clients sign
  # with RFC 6979 nonces, so the signature is deterministic.
  describe "EIP-155 example (secp256k1)" do
    @key :binary.copy(<<0x46>>, 32)
    @hash Base.decode16!("DAF5A779AE972F972197303D7B574746C7EF83EADAC0F2791AD23DB92E4C8E53")
    @r 18_515_461_264_373_351_373_200_002_665_853_028_612_451_056_578_545_711_640_558_177_340_181_847_433_846
    @s 46_948_507_304_638_947_509_940_763_649_030_358_759_909_902_576_025_900_602_547_168_820_602_576_006_531

    test "signs with v = 37, so recovery id 0" do
      assert ECDSA.sign(:secp256k1, @hash, @key) == {:ok, {@r, @s, 0}}
    end

    test "recovers the signer 0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F" do
      assert {:ok, {x, y}} = ECDSA.recover(:secp256k1, @hash, @r, @s, 0)
      assert {:ok, {x, y}} == ECDSA.public_key(:secp256k1, @key)
      <<_::96, address::160>> = Keccak.hash_256(<<x::256, y::256>>)
      assert address == 0x9D8A62F656A8D1615C1294FD71E9CFB3E4855A4F
    end

    test "the equivalent high s with the other recovery id recovers the same key" do
      n = ECDSA.order(:secp256k1)
      assert ECDSA.recover(:secp256k1, @hash, @r, n - @s, 1) == ECDSA.public_key(:secp256k1, @key)
    end

    test "the other recovery id recovers a different key" do
      assert {:ok, other} = ECDSA.recover(:secp256k1, @hash, @r, @s, 1)
      refute {:ok, other} == ECDSA.public_key(:secp256k1, @key)
    end
  end

  # Products whose expected value follows from the group law, not from eevm:
  # (n − 1)·G = −G, and on secp256k1 λ·G = φ(G) = (β·Gx, Gy) for the cube roots
  # of unity λ mod n and β mod p (Guide to ECC, Example 3.73). These scalars
  # split into GLV halves of opposite signs and the full 256-bit width.
  describe "scalar multiplication at GLV and wNAF boundaries" do
    @k1_p 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
    @k1_g {0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
           0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8}
    @lambda 0x5363AD4CC05C30E0A5261C028812645A122E22EA20816678DF02967C1B23BD72
    @beta 0x7AE96A2B657C07106E64479EAC3434E99CF0497512F58995C1396C28719501EE

    test "(n − 1)·G is −G on both curves" do
      p256_p = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
      {:ok, {p256_gx, p256_gy}} = ECDSA.public_key(:p256, <<1::256>>)
      {gx, gy} = @k1_g

      assert ECDSA.public_key(:secp256k1, <<ECDSA.order(:secp256k1) - 1::256>>) ==
               {:ok, {gx, @k1_p - gy}}

      assert ECDSA.public_key(:p256, <<@p256_n - 1::256>>) == {:ok, {p256_gx, p256_p - p256_gy}}
    end

    test "λ·G and (n − λ)·G are ±φ(G) on secp256k1" do
      {gx, gy} = @k1_g
      n = ECDSA.order(:secp256k1)
      phi_x = rem(@beta * gx, @k1_p)

      assert ECDSA.public_key(:secp256k1, <<@lambda::256>>) == {:ok, {phi_x, gy}}
      assert ECDSA.public_key(:secp256k1, <<n - @lambda::256>>) == {:ok, {phi_x, @k1_p - gy}}
    end

    test "recovery from s·R − e·G with e ≡ 0 (mod n) leaves only the R term" do
      # With e = n the G term vanishes: Q = r⁻¹·s·R. Taking s = r gives Q = R.
      n = ECDSA.order(:secp256k1)
      {gx, gy} = @k1_g
      assert ECDSA.recover(:secp256k1, <<n::256>>, gx, gx, gy &&& 1) == {:ok, @k1_g}
    end
  end

  describe "rejects" do
    test "private keys outside (0, n)" do
      for curve <- [:secp256k1, :p256], d <- [0, ECDSA.order(curve)] do
        assert ECDSA.public_key(curve, <<d::256>>) == {:error, :invalid_private_key}
        assert ECDSA.sign(curve, <<1::256>>, <<d::256>>) == {:error, :invalid_private_key}
      end
    end

    test "recovery with r or s outside (0, n)" do
      n = ECDSA.order(:secp256k1)

      for {r, s} <- [{0, 1}, {1, 0}, {n, 1}, {1, n}] do
        assert ECDSA.recover(:secp256k1, <<1::256>>, r, s, 0) == {:error, :invalid_signature}
      end
    end

    test "recovery when r + n is not below p (recovery id 2 or 3)" do
      n = ECDSA.order(:secp256k1)
      assert ECDSA.recover(:secp256k1, <<1::256>>, n - 1, 1, 2) == {:error, :invalid_signature}
    end

    test "verification against the point at infinity's (0, 0) encoding or an off-curve key" do
      r = 0xF1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367
      s = 0x019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083
      {x, y} = @p256_public
      hash = SHA256.hash("test")

      refute ECDSA.verify(:p256, hash, r, s, {0, 0})
      refute ECDSA.verify(:p256, hash, r, s, {x, y + 1})
      refute ECDSA.verify(:p256, hash, r, @p256_n + s, {x, y})
    end
  end
end
