# Adding an opcode, a precompile, or a fork-gated rule

Read the commit of a similar change before starting: `git show f5e161f` (CLZ, EIP-7939), `git show 92b550c` (P256VERIFY, EIP-7951), `git show 25d871a` (ModExp repricing, EIP-7883).

## A fork flag

Every rule that starts at a hardfork needs a flag, including a new opcode or precompile.

1. Add `eip_NNNN: :fork` to `@eip_activation` in `lib/eevm/hardfork_config.ex`, with a comment that names the EIP and what it does. Add the EIP to the fork's row of the moduledoc table.
2. Branch with `HardforkConfig.enabled?(hardfork, :eip_NNNN)`. Interpreter code reaches the hardfork through `state.env.config.hardfork`.
3. In `test/hardfork_config_test.exs`, assert that the flag is enabled at the fork and disabled at the fork before it.

## An opcode

1. In `lib/eevm/interpreter/instructions/registry.ex`, add a module attribute for the byte and an `@opcodes` entry: `name`, `inputs`, `outputs`, `module`, plus `eip: :eip_NNNN` when it is new after Frontier and `state_mutating: true` when it must halt inside STATICCALL. `EEVM.Interpreter.InstructionTable` builds each fork's table from these entries, so the opcode has no other dispatch to wire up.
2. In `lib/eevm/gas/static.ex`, add a `static_cost/1` clause with a comment citing the EIP. Put size- or state-dependent costs in `EEVM.Gas.Dynamic`.
3. Implement it in the family module. `Arithmetic`, `Bitwise`, `Comparison`, and `StackOps` are pure stack modules: add a `stack_op(opcode, stack)` clause that takes and returns the stack list. Every other module gets an `execute(opcode, state)` clause that returns `{:ok, state}` or `{:error, reason, state}`.
4. Add the byte to the `standard_opcodes` ranges in `test/interpreter/instructions/exhaustiveness_test.exs`.
5. Add cases to the family's test under `test/interpreter/instructions/`, with values from the EIP's test cases. Include the fork before activation, where the byte must halt as invalid.

## A precompile

1. Create `lib/eevm/precompiles/<name>.ex` with `@behaviour EEVM.Precompile` and `execute(input, gas_limit)`. It returns `{:ok, output, gas_used}` or `{:error, reason}`. An error consumes all the gas the caller forwarded.
2. Add a row to `@builtins` in `lib/eevm/precompiles.ex`: `{address, :eip_NNNN, Module, :execute, receives_hardfork?}`. Set the last field to `true` when the price or rules change in a later fork. The function then gets the `HardforkConfig` as a third argument and branches on its flags, as `ModExp.execute/3` does. Add the module to the alias list and the address to the moduledoc table.
3. Update the precompile list in `README.md` and in `lib/eevm.ex`'s moduledoc.
4. Check in the EIP's vectors under `test/fixtures/precompiles/` with a line in its README, and test against them in `test/precompiles/<name>_test.exs`.
5. Benchmark it (`reference/benchmarking.md`). An input that costs much less gas than the time it takes is a denial-of-service risk, so file an issue for it.

## Check against the fixtures

Run the EIP's EEST directory, add `--fork osaka` for an Osaka EIP, then the full ratchets your change can affect. See `reference/conformance.md`.

```bash
mix eevm.state_tests 'test/fixtures/eest/fixtures_develop/state_tests/osaka/eip7939_count_leading_zeros/**/*.json' --fork osaka
```
