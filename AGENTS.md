# AGENTS.md

eevm is an Ethereum Virtual Machine written in pure Elixir, embedded as a library. It is its own implementation: never wrap or call out to revm, evmone, or another EVM.

## Checks

Run all of these before every push; CI runs the same set.

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix test --warnings-as-errors
mix docs --warnings-as-errors
```

`mix quality` runs the first five. The minimum is Elixir 1.18 / OTP 27; CI also tests Elixir 1.19 / OTP 28. Official fixtures run through `mix eevm.state_tests` and `mix eevm.blockchain_tests`, not `mix test`.

## Hard rules

- No native code: no NIFs, no `:crypto` or `:public_key`, no Rust. Write crypto in Elixir, in `lib/eevm/crypto/` or the precompile that owns it. `test/purity_test.exs` also keeps `lib/` free of ETS, processes, the process dictionary, files, OS calls, and clocks.
- Call Logger only at the edges: Database adapters, Mix tasks, and opt-in diagnostics.
- Raise `ArgumentError` for mistakes in the caller's own arguments, such as a hex string passed to `run/2`. Return `{:error, reason}` for data that can come from outside, such as raw transactions, blocks, ABI data, and backend reads. Catalogue each new error atom, with a message, in `EEVM.Error`.
- Gate every fork-dependent rule on an `:eip_NNNN` flag in `@eip_activation` (`lib/eevm/hardfork_config.ex`), through the `HardforkConfig.enabled?/2` macro with a literal flag, so a misspelled flag fails to compile. Never compare fork names.
- The "Getting started", "Transactions", "Blocks", and "State" groups in `docs/0` of `mix.exs` are the public API, "Extending" holds extension points, and "Internals" may change freely. Deprecate with `@deprecated` delegates for one minor version before removing public API.

## Layout

- `lib/eevm.ex`: the entry points `run/2`, `call/4`, `create/3`, and `transact/4`. `lib/eevm/block.ex` and `lib/eevm/block/`: blocks.
- `lib/eevm/interpreter.ex`: the fetch-decode-execute loop. Opcode metadata is in `interpreter/instructions/registry.ex`, and semantics are in `interpreter/instructions/` by family.
- `lib/eevm/handler.ex` and `handler/`: one transaction through validation, pre-execution, execution, and post-execution.
- `lib/eevm/gas/` and `transaction/intrinsic_gas.ex`: gas.
- `lib/eevm/precompiles/<name>.ex`: one module per precompile, registered by address in `precompiles.ex`.
- `lib/eevm/database.ex`: the read-only backend behaviour and eevm's write overlay. `mpt/` and `state_root.ex`: tries and roots.

## Code conventions

- Dispatch with multi-clause functions and pattern matching in heads, as `execute/2` in each `Instructions.*` module does, not `case` ladders on opcode bytes.
- Keep functions pure: each step takes a `MachineState` and returns a new one. Public functions return `{:ok, value}` or `{:error, reason}`; opcode handlers return `{:ok, state}` or `{:error, reason, state}`.
- Give every public function `@spec` and `@doc` and every module `@moduledoc`. Cite the EIP or Yellow Paper section for non-obvious rules.
- Add no wrappers, behaviours, or helper modules with one caller; extend the module that owns the behaviour.
- Represent EVM words as integers and byte data as binaries. On hot paths, don't rebuild structs or binaries per opcode, and keep optional features free when off, as `tracer: nil` costs one pattern match.
- Benchmark any change to the interpreter, gas, opcodes, crypto, or precompiles with `mix bench` before and after on the same machine, and put the numbers in the commit message.
- Fix Credo and Dialyzer findings in the code; `dialyzer_ignore.exs` is for genuine false positives only.

## Testing

- Derive expected values from the spec, not from eevm's output: EIP test cases, Yellow Paper formulas, published vectors, or values from geth or revm. Cite the source, and cover both sides of every boundary and fork transition.
- Tests mirror `lib/` under `test/` and use `async: true` unless they need global state. Call a deprecated function through `apply/3` so its warning doesn't fail the build.
- `test/docs/` runs every README and moduledoc example, lints public docs for calls to Internals or deprecated API, and checks the README's conformance table against the fixture lists. A `#=> value` line asserts a match; `<!-- docs-check: skip -->` skips the next block.
- CI's Conformance jobs fail on any case that a `known_failures*.txt` list doesn't cover. Commit regenerated lists with the fix that changes them. Don't claim conformance the suites don't show.
- The `developing-eevm` skill (`.agents/skills/developing-eevm/`) has the steps for opcodes, precompiles, EIPs, conformance lists, and benchmarking.

## Workflow

- Commit directly to `main`, without pull requests. Before pushing, run `git fetch origin && git rebase origin/main` and the checks, then push and confirm the commit's CI run passes. Other agents push in parallel; resolve conflicts keeping both sides' intent.
- GitHub Issues are the task board. Pick work there, and file issues for bugs and follow-ups you find.
- Keep each commit to one logical change, with a Conventional Commit subject such as `feat(tx): ...` or `fix(gas): ...`, and `Closes #N` in the body of the commit that finishes issue N.
- Don't tag, publish to Hex, or add Hex package metadata; releases are the owner's call.
