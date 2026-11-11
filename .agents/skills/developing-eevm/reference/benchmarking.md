# Benchmarking

`mix bench` always builds with `MIX_ENV=prod`. Each suite runs every job once and checks its result before timing, then prints Benchee's report and a `Gas throughput` table. Compare Mgas/s.

```bash
mix bench interpreter      # bench/interpreter_bench.exs: interpreter, stack, memory, gas, opcodes, calls
mix bench precompiles      # bench/precompiles_bench.exs
mix bench ecdsa            # bench/ecdsa_bench.exs: secp256k1 recover/sign, P-256, P256VERIFY
mix bench                  # all three
mix bench state_fixtures   # the slow ethereum/tests fixtures that skip.txt holds back; needs the submodule
```

A suite takes about 4.5 s per job (1 s warmup, 3 s timing, 0.5 s memory), so about a minute for `interpreter`.

## Before and after

Run the base and the change on the same machine, alternately, at least twice each. Shared hardware varies by ±5–10%, so treat smaller differences as noise.

```bash
git stash -u && mix bench interpreter > /tmp/before-1.txt
git stash pop && mix bench interpreter > /tmp/after-1.txt
git stash -u && mix bench interpreter > /tmp/before-2.txt
git stash pop && mix bench interpreter > /tmp/after-2.txt
grep -A16 'Gas throughput' /tmp/before-*.txt /tmp/after-*.txt
```

For committed work, check out the base commit's `lib/` instead of stashing. Put a table of Mgas/s before and after, and memory per run where it moved, in the commit message, with the base commit and the machine. A change that makes one workload faster and another slower needs both rows.

Read the table with care. The storage scenario's Mgas/s is high because cold SSTOREs are priced for disk an in-memory database never touches. A job that halts exceptionally burns its remaining gas at once, so compare its time, not Mgas/s.

## Profiling

```bash
MIX_ENV=prod mix profile.tprof --warmup --sort time bench/profile.exs
```

`bench/profile.exs` runs a 20k-iteration arithmetic loop. Edit its program to profile another workload; `bench/support/asm.exs` assembles programs from opcode names.

## Adding a workload

Add a job to the suite as `name => {gas_per_run, fun}` for `EEVM.Bench.run/1` (`bench/support/bench.exs`), with the gas measured by running the job once and checking its result, as the existing jobs do. Describe a new scenario in the tables of `bench/README.md`. Record the before-and-after table there too for a change that moves a workload by a large factor. `mix docs` publishes the README as the Benchmarks page, so it must keep building without warnings.
