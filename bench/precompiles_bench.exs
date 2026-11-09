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
private_key = :crypto.hash(:sha256, "eevm benchmark signer")
hash = :crypto.hash(:sha256, "eevm benchmark message")
{:ok, {<<r::256, s::256>>, recovery_id}} = ExSecp256k1.sign_compact(hash, private_key)
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

# BLS12-381 pairing (0x0F): the G1 generator with the G2 generator.
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

inputs = %{
  "ecrecover (0x01)" => {0x01, ecrecover_input},
  "sha256 1 KiB (0x02)" => {0x02, :rand.bytes(1024)},
  "ripemd160 1 KiB (0x03)" => {0x03, :rand.bytes(1024)},
  "identity 1 KiB (0x04)" => {0x04, :rand.bytes(1024)},
  "modexp 2048-bit (0x05)" => {0x05, modexp_input},
  "bn256 pairing, 2 pairs (0x08)" => {0x08, bn_pairing_input},
  "bls12-381 pairing, 1 pair (0x0F)" => {0x0F, bls_g1 <> bls_g2}
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
