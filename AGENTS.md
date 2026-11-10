# AGENTS.md

How to change eevm.

## Goal

eevm is a production-grade Ethereum Virtual Machine written entirely in Elixir.
Never wrap or call out to revm, evmone, or any other EVM. The only native code is
the Rustler NIF in `native/eevm_bls`, and it does BLS12-381 curve arithmetic
only. New crypto that Erlang/OTP or existing deps (`ex_secp256k1`)
cannot provide needs a good reason before it becomes another NIF.

Developers embed eevm as a library. In `docs/0` of `mix.exs`, the groups
"Getting started", "Transactions", "Blocks", and "State" are the public API,
"Extending" holds extension points, and "Internals" may change freely. Keep the
public API small and documented, and deprecate (`@deprecated` delegates for one
minor version) before removing anything (#150).

## Code quality

- Write idiomatic Elixir. Dispatch with multi-clause functions and pattern
  matching in heads (see `execute/2` in each `Instructions.*` module and
  `Gas.Static.static_cost/1`), not `case` ladders on opcode bytes.
- Keep functions small and pure. Every step takes a `MachineState` and returns a
  new one. `test/purity_test.exs` keeps `lib/` free of ETS, processes, the
  process dictionary, files, OS calls, clocks, NIFs, and `:crypto`.
- Public functions return `{:ok, value}` / `{:error, reason}`; opcode handlers
  return `{:ok, state}` or `{:error, reason, state}`. Chain fallible steps with
  `with`. Raise only for programmer errors. Catalogue new error atoms, with a
  message, in `EEVM.Error`.
- Give every public function `@spec` and `@doc` and every module `@moduledoc`,
  adding missing ones where you touch. Prefer doctests for small examples.
- Cite the EIP or Yellow Paper section for non-obvious rules.
- No wrappers, behaviours, or helper modules with one caller; extend the module
  that owns the behaviour. `Instructions.Helpers` holds helpers shared across
  opcode families.
- Credo runs strict with 120-character lines. Fix the code instead of silencing
  Credo or Dialyzer; `dialyzer_ignore.exs` is for genuine false positives.

## Performance

- Represent EVM words as integers and byte data as binaries; use binary pattern
  matching and `binary_part/3`, not lists.
- Avoid copying: don't rebuild large structs or binaries per opcode, don't
  `Enum.reverse`/`++` on hot paths, and update only the struct fields you change
  (`MachineState.update_frame/2`).
- Keep disabled features free: the tracer costs one pattern match when
  `tracer: nil`. Follow that model for anything optional.
- Benchmark any change to the interpreter, stack, memory, gas, or opcode
  handlers: run `MIX_ENV=prod mix run bench/interpreter_bench.exs` before and
  after on the same machine and put the numbers in the commit message.

## Layout

| What | Where |
|------|-------|
| Public entry points | `lib/eevm.ex` (`run/2`, `transact/4`, `disassemble/1`), `lib/eevm/block.ex` |
| Fetch-decode-execute loop, refunds | `lib/eevm/interpreter.ex` |
| Opcode metadata (name, stack I/O, module, static flag) | `lib/eevm/interpreter/instructions/registry.ex` |
| Opcode semantics | `lib/eevm/interpreter/instructions/` by family (`arithmetic.ex`, `system/calls.ex`, ...) |
| Machine state, stack, memory, call-frame merge | `lib/eevm/interpreter/` (`machine_state/`, `stack.ex`, `memory.ex`, `journal.ex`) |
| Gas: static, dynamic, memory, warm/cold, intrinsic | `lib/eevm/gas/`, plus `lib/eevm/transaction/intrinsic_gas.ex` |
| Precompiles | `lib/eevm/precompiles/<name>.ex` implementing `EEVM.Precompile`, registered by address in `lib/eevm/precompiles.ex` |
| BLS12-381 NIF | `native/eevm_bls` (Rust), loaded by `lib/eevm/precompiles/bls12381/nif.ex` |
| Hardforks | `lib/eevm/hardfork_config.ex` (`@spec_order`, `@eip_activation`), carried in `EEVM.Config` |
| Transaction pipeline | `lib/eevm/handler.ex` plus `handler/validation.ex`, `pre_execution.ex`, `execution.ex`, `post_execution.ex` |
| Transactions (structs, envelopes, signing, validation) | `lib/eevm/transaction.ex`, `lib/eevm/transaction/` |
| Blocks, receipts, bloom, withdrawals | `lib/eevm/block/` |
| System contracts (EIP-4788, EIP-2935) | `lib/eevm/system_contracts/` |
| State and tries | `lib/eevm/database.ex` (read-only behaviour, write overlay), `database/in_memory.ex`, `mpt/`, `state_root.ex` |

Adding an opcode: add it to the Registry `@opcodes` map with its `module`, add
its static cost to `Gas.Static`, implement an `execute/2` clause in that module,
and add tests under `test/interpreter/instructions/`.

Adding a fork-dependent rule: add an `:eip_NNNN` flag to `@eip_activation` and
branch on `HardforkConfig.enabled?(state.env.config.hardfork, :eip_NNNN)`. Never
compare fork names directly.

## Checks

CI (`.github/workflows/ci.yml`) runs these. Run all of them before every push:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix test
mix docs   # must emit no ExDoc warnings
```

`mix quality` runs the first five. CI also tests Elixir 1.19 / OTP 28; the
minimum is Elixir 1.18 / OTP 27. Never push with a failing check; confirm your
commit's CI run passes.

## Testing

- Derive expected values from the spec, not from eevm's output: EIP test cases,
  Yellow Paper formulas, NIST vectors (see `test/precompiles/sha256_test.exs`),
  or values from geth/revm. Cite the source in the test. Cover both sides of
  every boundary and fork transition.
- Tests mirror `lib/` under `test/`, with shared builders in `test/support/`.
  Use `async: true` unless a test needs global state.
- Official fixtures run through Mix tasks, not `mix test`. The pinned
  execution-spec-tests release (`test/fixtures/eest/fetch.sh`) is the
  authoritative suite for current forks; the `ethereum/tests` submodule is the
  legacy suite:

  ```bash
  test/fixtures/eest/fetch.sh
  mix eevm.state_tests 'test/fixtures/eest/fixtures/state_tests/prague/**/*.json'
  test/fixtures/eest/fetch.sh develop   # Osaka: run with --fork osaka
  mix eevm.state_tests 'test/fixtures/eest/fixtures_develop/state_tests/osaka/**/*.json' --fork osaka
  git submodule update --init --depth 1 test/fixtures/state_tests/ethereum-tests
  mix eevm.state_tests 'test/fixtures/state_tests/ethereum-tests/GeneralStateTests/stExample/*.json'
  mix eevm.blockchain_tests 'test/fixtures/state_tests/ethereum-tests/BlockchainTests/ValidBlocks/**/*.json'
  ```

  CI's Conformance jobs run every suite against its `known_failures*.txt` list
  and fail on any failure a list doesn't cover. When you fix failures, regenerate the lists with the commands in their
  headers and commit them with the fix. `stale_fixtures.txt` lists fixtures
  older than a rule eevm implements. `test/fixtures/*/skip.txt` is only for
  fixtures that abort the VM or cannot finish within the per-case timeout.
- `README.md` is doctested from `test/eevm_test.exs`; keep its examples running.
- Don't claim conformance the suites don't show.

## Workflow

- Commit directly to `main`; no pull requests.
- Before pushing: `git fetch origin && git rebase origin/main`, rerun the
  checks, then push. Other agents push in parallel; resolve conflicts keeping
  both sides' intent.
- GitHub Issues are the task board: pick work there, file issues for bugs and
  follow-ups you find, and keep each commit to one logical change.
- Use Conventional Commit subjects: `feat(tx): ...`, `fix(gas): ...`,
  `docs: ...`.
- Put `Closes #N` in the body of the commit that finishes issue N.
- Don't tag, publish to Hex, or add Hex package metadata; releases are the
  owner's call.
