# Precompile workloads: run with `mix bench precompiles` (or `mix bench` for every suite).
#
# Each job calls `EEVM.Precompiles.execute/4` directly with valid input, so it measures
# the precompile itself without interpreter overhead.

Code.require_file("support/bench.exs", __DIR__)

alias EEVM.{Config, Precompiles}

# Fixed seed: random inputs are the same on every run.
:rand.seed(:exsss, {1, 2, 3})

config = Config.new(:prague)
gas = 10_000_000

# ecrecover (0x01): a real signature over a 32-byte hash.
private_key = EEVM.Crypto.SHA256.hash("eevm benchmark signer")
hash = EEVM.Crypto.SHA256.hash("eevm benchmark message")
{:ok, {r, s, recovery_id}} = EEVM.Crypto.ECDSA.sign(:secp256k1, hash, private_key)
ecrecover_input = <<hash::binary, 27 + recovery_id::256, r::256, s::256>>

# ModExp (0x05): a 2048-bit modular exponentiation, as in RSA signature checks.
modulus = :rand.bytes(256)
base = :rand.bytes(256)
exponent = :rand.bytes(256)
modexp_input = <<256::256, 256::256, 256::256, base::binary, exponent::binary, modulus::binary>>

# BN256 pairing (0x08): G1 generator with G2 generator and its negation (result 1).
bn_g1 = <<1::256, 2::256>>

bn_g2 =
  <<0x198E9393920D483A7260BFB731FB5D25F1AA493335A9E71297E485B7AEF312C2::256,
    0x1800DEEF121F1E76426A00665E5C4479674322D4F75EDADD46DEBD5CD992F6ED::256,
    0x090689D0585FF075EC9E99AD690C3395BC4B313370B38EF355ACDADCD122975B::256,
    0x12C85EA5DB8C6DEB4AAB71808DCB408FE3D1E7690C43D37B4CE6CC0166FA7DAA::256>>

bn_neg_g1 = <<1::256, 0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD45::256>>
bn_pairing_input = bn_g1 <> bn_g2 <> bn_neg_g1 <> bn_g2

# BN256 ecAdd (0x06) and ecMul (0x07): G1 + 2·G1, and G1 times a random 256-bit scalar.
bn_2g1 =
  <<0x030644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD3::256,
    0x15ED738C0E0A7C92E7845F96B2AE9C0A68A6A449E3538FC7FF3EBF7A5A18A2C4::256>>

bn_mul_input = bn_g1 <> :rand.bytes(32)

# BLS12-381 (0x0B-0x11). Points are random multiples of the generators, made with
# the G1MSM and G2MSM precompiles themselves.
pad = fn hex -> <<0::128, Base.decode16!(hex, case: :lower)::binary>> end

bls_g1 =
  pad.(
    "17f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb"
  ) <>
    pad.(
      "08b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1"
    )

bls_g2 =
  pad.(
    "024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb8"
  ) <>
    pad.(
      "13e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e"
    ) <>
    pad.(
      "0ce5d527727d6e118cc9cdc6da2e351aadfd9baa8cbdd3a76d429a695160d12c923ac9cc3baca289e193548608b82801"
    ) <>
    pad.(
      "0606c4a02ea734cc32acd2b02bc28b99cb3e287e85a763af267492ab572e99ab3f370d275cec1da1aaa9075ff05f79be"
    )

bls_scalar = fn -> :rand.bytes(32) end

bls_mul = fn address, point ->
  {:ok, product, _gas} = Precompiles.execute(address, point <> bls_scalar.(), gas, config)
  product
end

bls_g1_point = fn -> bls_mul.(0x0C, bls_g1) end
bls_g2_point = fn -> bls_mul.(0x0E, bls_g2) end
bls_msm_input = fn point, n -> for _ <- 1..n, into: <<>>, do: point.() <> bls_scalar.() end

bls_fp = fn ->
  <<0::128,
    rem(
      :binary.decode_unsigned(:rand.bytes(48)),
      0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAB
    )::384>>
end

# KZG point evaluation (0x0A): c-kzg-4844's verify_kzg_proof vector correct_proof_2_2.
kzg_vector =
  "test/fixtures/precompiles/kzg_verify_proof_vectors.json"
  |> File.read!()
  |> Jason.decode!()
  |> Enum.find(&(&1["name"] == "verify_kzg_proof_case_correct_proof_2_2"))
  |> Map.fetch!("input")
  |> Map.new(fn {key, hex} ->
    {key, Base.decode16!(String.trim_leading(hex, "0x"), case: :lower)}
  end)

<<_version, kzg_hash_tail::binary-size(31)>> = EEVM.Crypto.SHA256.hash(kzg_vector["commitment"])

kzg_input =
  <<1, kzg_hash_tail::binary, kzg_vector["z"]::binary, kzg_vector["y"]::binary,
    kzg_vector["commitment"]::binary, kzg_vector["proof"]::binary>>

# BLAKE2F (0x09): EIP-152 test vector 5 ("abc", final block), with the round count
# replaced. 12 rounds is one BLAKE2b compression; 1M rounds is the per-round cost that
# dominates the stPreCompiledContracts2 Blake2f fixtures (8M rounds per call).
blake2f_h =
  Base.decode16!(
    "48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5" <>
      "d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b",
    case: :lower
  )

# rounds | h | m = "abc" zero-padded to 128 bytes | t = (3, 0) | f = 1
blake2f_input = fn rounds ->
  <<rounds::32, blake2f_h::binary, "abc", 0::size(125 * 8), 3::little-64, 0::little-64, 1>>
end

inputs = %{
  "ecrecover (0x01)" => {0x01, ecrecover_input},
  "sha256 1 KiB (0x02)" => {0x02, :rand.bytes(1024)},
  "ripemd160 1 KiB (0x03)" => {0x03, :rand.bytes(1024)},
  "identity 1 KiB (0x04)" => {0x04, :rand.bytes(1024)},
  "modexp 2048-bit (0x05)" => {0x05, modexp_input},
  "bn256 add (0x06)" => {0x06, bn_g1 <> bn_2g1},
  "bn256 mul (0x07)" => {0x07, bn_mul_input},
  "bn256 pairing, 2 pairs (0x08)" => {0x08, bn_pairing_input},
  "blake2f 12 rounds (0x09)" => {0x09, blake2f_input.(12)},
  "blake2f 1M rounds (0x09)" => {0x09, blake2f_input.(1_000_000)},
  "kzg point evaluation (0x0A)" => {0x0A, kzg_input},
  "bls12-381 g1add (0x0B)" => {0x0B, bls_g1_point.() <> bls_g1_point.()},
  "bls12-381 g1msm, 1 pair (0x0C)" => {0x0C, bls_msm_input.(bls_g1_point, 1)},
  "bls12-381 g1msm, 128 pairs (0x0C)" => {0x0C, bls_msm_input.(bls_g1_point, 128)},
  "bls12-381 g2add (0x0D)" => {0x0D, bls_g2_point.() <> bls_g2_point.()},
  "bls12-381 g2msm, 1 pair (0x0E)" => {0x0E, bls_msm_input.(bls_g2_point, 1)},
  "bls12-381 g2msm, 128 pairs (0x0E)" => {0x0E, bls_msm_input.(bls_g2_point, 128)},
  "bls12-381 pairing, 1 pair (0x0F)" => {0x0F, bls_g1 <> bls_g2},
  "bls12-381 pairing, 2 pairs (0x0F)" =>
    {0x0F, bls_g1_point.() <> bls_g2_point.() <> bls_g1_point.() <> bls_g2_point.()},
  "bls12-381 map fp to g1 (0x10)" => {0x10, bls_fp.()},
  "bls12-381 map fp2 to g2 (0x11)" => {0x11, bls_fp.() <> bls_fp.()}
}

# Run every job once to measure its gas, and drop any that fails so one broken
# precompile doesn't stop the suite.
for {name, {address, input}} <- Enum.sort(inputs),
    run = fn -> Precompiles.execute(address, input, gas, config) end,
    result = run.(),
    IO.puts("#{String.pad_trailing(name, 34)} #{inspect(result, limit: 2)}"),
    {:ok, _output, used} <- [result],
    into: %{} do
  {name, {used, run}}
end
|> EEVM.Bench.run()
