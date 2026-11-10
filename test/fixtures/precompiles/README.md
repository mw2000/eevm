# Precompile Test Vectors

Official vectors, checked in verbatim:

- `modexp_eip7883_vectors.json` — ModExp vectors with EIP-2565 (`GasOld`) and
  EIP-7883 (`GasNew`) gas costs, from
  [execution-spec-tests v5.4.0](https://github.com/ethereum/execution-spec-tests/blob/v5.4.0/tests/osaka/eip7883_modexp_gas_increase/vector/vectors.json).
- `p256verify_eip7951_vectors.json` — P256VERIFY vectors (mostly Wycheproof)
  from [EIP-7951](https://eips.ethereum.org/assets/eip-7951/test-vectors.json).
  Their `Gas` field is the RIP-7212 cost (3450); EIP-7951 charges 6900.
- `bn256_pairing_eip197_vectors.json` — alt_bn128 pairing (EIP-197) vectors with
  Istanbul gas costs, from go-ethereum's
  [`core/vm/testdata/precompiles/bn256Pairing.json`](https://github.com/ethereum/go-ethereum/blob/master/core/vm/testdata/precompiles/bn256Pairing.json).
- `bn256_add_eip196_vectors.json` and `bn256_scalar_mul_eip196_vectors.json` —
  alt_bn128 ecAdd and ecMul (EIP-196) vectors with Istanbul gas costs, from
  go-ethereum's
  [`bn256Add.json`](https://github.com/ethereum/go-ethereum/blob/master/core/vm/testdata/precompiles/bn256Add.json)
  and
  [`bn256ScalarMul.json`](https://github.com/ethereum/go-ethereum/blob/master/core/vm/testdata/precompiles/bn256ScalarMul.json).
- `bls12381_eip2537_*.json` — BLS12-381 (EIP-2537) vectors from
  [`assets/eip-2537`](https://github.com/ethereum/EIPs/tree/faaa35fff856a109c40d291e612447fadc2095fe/assets/eip-2537),
  with `-` in the file names replaced by `_`: `add`, `mul`, `pairing_check`,
  `map_fp_to_G1`, and `map_fp2_to_G2`, and every `fail-*` file. The success
  `msm_G1_bls.json` and `msm_G2_bls.json` (10 MB together) are left out;
  the EEST `prague/eip2537_bls_12_381_precompiles` fixtures cover MSM.
- `kzg_verify_proof_vectors.json` — KZG `verify_kzg_proof` (EIP-4844 point
  evaluation) vectors from c-kzg-4844's
  [`tests/verify_kzg_proof/kzg-mainnet`](https://github.com/ethereum/c-kzg-4844/tree/main/tests/verify_kzg_proof/kzg-mainnet),
  converted from one `data.yaml` per case to JSON (`name`, `input`, `output`).
