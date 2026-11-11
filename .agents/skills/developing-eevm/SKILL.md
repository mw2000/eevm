---
name: developing-eevm
description: "Step-by-step workflows for changing eevm, the pure-Elixir EVM: adding an opcode, precompile, or EIP rule behind a hardfork flag; running mix eevm.state_tests and mix eevm.blockchain_tests and regenerating known_failures, skip.txt, or stale_fixtures lists; benchmarking with mix bench; and fixing test/purity_test.exs or the CI native-code check. Use when implementing an EIP or fork, fixing conformance failures, or changing interpreter, gas, crypto, or precompile performance."
---

# Developing eevm

AGENTS.md holds eevm's conventions, layout, and checks. This skill holds the workflows for specific tasks. Read the reference file for the task you are on:

- Adding an opcode, a precompile, or any rule that starts at a hardfork: `reference/eips.md`.
- Running the conformance suites, reading their output, or changing `known_failures*.txt`, `skip.txt`, or `stale_fixtures.txt`: `reference/conformance.md`.
- Measuring a change to the interpreter, stack, memory, gas, opcodes, crypto, or precompiles: `reference/benchmarking.md`.

## Purity

Two CI checks keep `lib/` free of native code and side effects:

- `mix test test/purity_test.exs` reads the remote calls compiled into every `lib/` module, so it also catches calls behind aliases, imports, and macros.
- The Lint job runs `! grep -rnE ':crypto|:public_key|Rustler|NIF' lib mix.exs`. It is a plain text search, so `NIF` or `:crypto` in a comment or `@doc` under `lib/` fails CI too. Write "native code" instead.

When the purity test fails, move the effect to an edge or pass the value in as an argument. Edges are `test/support/` (the fixture harness and the `mix eevm.*` tasks), `bench/`, and Database adapters. The test's `@allowed` map lists known violations with the issue that removes each. It only shrinks, and the test fails on an entry nothing needs, so never add to it.

For crypto, reuse `EEVM.Crypto.Keccak`, `SHA256`, `RIPEMD160`, and `ECDSA` (`lib/eevm/crypto/`) and the curve modules `EEVM.Precompiles.BN256.Curve` and `EEVM.Precompiles.Bls12381.Curve`. Test a new primitive against published vectors (see `test/fixtures/precompiles/README.md`), then benchmark it. Pure Elixir runs several times slower than native code, and gas prices assume native speed.

The purity test does not check `Logger`. Before committing, check by hand that any new `Logger` call is in a Database adapter, a Mix task, or opt-in diagnostics.

## Gotchas

- Regenerate a `known_failures*.txt` only with the exact command in its header. `--write-known-failures` keeps only the failures of the run you made and copies your command into the header, so a narrower glob or a missing `--fork` silently deletes entries.
- Check Prague and Osaka rules against the EEST fixtures. Prague BlockchainTests in the pinned `ethereum/tests` snapshot predate EIP-7002 and EIP-7251 and fail with `:system_contract_empty`.
- Never edit `skip.txt` to get past failures. It holds only fixtures that crash the VM or cannot finish in time; a fixture that runs and fails belongs in a known-failures list.
- Compare benchmark numbers only between runs on the same machine. The tables in `bench/README.md` come from other orbs and are not a baseline.
