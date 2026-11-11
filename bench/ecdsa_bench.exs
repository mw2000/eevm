# ECDSA workloads: run with `mix bench ecdsa` (or `mix bench` for every suite).
#
# EEVM.Crypto.ECDSA on its own: secp256k1 recovery (ECRECOVER and every signed
# transaction), signing, and P-256 verification (P256VERIFY), plus the P256VERIFY
# precompile, which is Osaka-only and so missing from the precompiles suite.

Code.require_file("support/bench.exs", __DIR__)

alias EEVM.Crypto.{ECDSA, SHA256}

private_key = SHA256.hash("eevm benchmark signer")
hash = SHA256.hash("eevm benchmark message")

{:ok, {r, s, recovery_id}} = ECDSA.sign(:secp256k1, hash, private_key)
{:ok, _signer} = ECDSA.recover(:secp256k1, hash, r, s, recovery_id)

{:ok, {qx, qy} = public_key} = ECDSA.public_key(:p256, private_key)
{:ok, {p256_r, p256_s, _}} = ECDSA.sign(:p256, hash, private_key)
true = ECDSA.verify(:p256, hash, p256_r, p256_s, public_key)

config = EEVM.Config.new(:osaka)
p256verify_input = <<hash::binary, p256_r::256, p256_s::256, qx::256, qy::256>>

{:ok, <<1::256>>, p256verify_gas} =
  EEVM.Precompiles.execute(0x100, p256verify_input, 100_000, config)

Benchee.run(
  %{
    "secp256k1 recover" => fn -> ECDSA.recover(:secp256k1, hash, r, s, recovery_id) end,
    "secp256k1 sign" => fn -> ECDSA.sign(:secp256k1, hash, private_key) end,
    "p256 verify" => fn -> ECDSA.verify(:p256, hash, p256_r, p256_s, public_key) end
  },
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

EEVM.Bench.run(%{
  "p256verify (0x100)" =>
    {p256verify_gas, fn -> EEVM.Precompiles.execute(0x100, p256verify_input, 100_000, config) end}
})
