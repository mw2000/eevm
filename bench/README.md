# Benchmarks

eevm's benchmark suite uses [Benchee](https://github.com/bencheeorg/benchee). Run it
from the repository root:

```bash
mix bench                  # every suite in bench/*_bench.exs except state_fixtures
mix bench interpreter      # only bench/interpreter_bench.exs
mix bench precompiles      # only bench/precompiles_bench.exs
mix bench state_fixtures   # the slow ethereum/tests fixtures (needs the submodule)
```

`mix bench` always runs with `MIX_ENV=prod`, the build users run. Before timing, each
suite runs every job once and checks the result, so a broken workload fails instead of
benchmarking an error path. After Benchee's own report, each suite prints a
gas-throughput table: gas per run, runs per second (ips), and Mgas/s (gas × ips).

## Workloads

`bench/interpreter_bench.exs` runs complete programs through `EEVM.Interpreter.run/2`, plus
one transaction through `EEVM.Handler.execute/4`. The programs are written with the
small assembler in `bench/support/asm.exs`.

| Scenario | What it runs |
|---|---|
| compute: arithmetic loop (50k) | ADD/MUL/AND on a stack accumulator with DUP/SWAP/POP and a JUMPI loop |
| compute: jump loop (100k) | The smallest loop body: decrement and JUMPI |
| memory: MSTORE/MLOAD 32 KiB | MSTORE then MLOAD at 1,024 word offsets, growing memory to 32 KiB |
| memory: 1k MSTOREs over 1 MiB | 1,024 MSTOREs spaced 1 KiB apart, growing memory to 1 MiB |
| memory: CALLDATACOPY+MCOPY+RETURN 32 KiB | Copies 32 KiB of calldata into memory, MCOPYs it, RETURNs 64 KiB |
| keccak: 5k x 32 B | KECCAK256 of a fresh 32-byte word, 5,000 times |
| keccak: 64 KiB | One KECCAK256 over 64 KiB of memory |
| storage: SSTORE/SLOAD 500 slots | Cold SSTORE then warm SLOAD of 500 slots |
| calls: STATICCALL loop (2k) | 2,000 STATICCALLs to a contract that SLOADs and MSTOREs (stStaticCall/static_Call50000-style) |
| erc20: transfer via Handler | A signed legacy `transfer(address,uint256)` with two SLOAD/SSTOREs and a LOG3 |

`bench/precompiles_bench.exs` calls `EEVM.Precompiles.execute/4` directly with valid
inputs: ecrecover, sha256, ripemd160, and identity (1 KiB), a 2048-bit ModExp, BN256
ecAdd, ecMul with a random 256-bit scalar, a two-pair BN256 pairing, BLAKE2F at 12 and 1M rounds, and a one-pair BLS12-381 pairing.

`bench/state_fixtures_bench.exs` times the ethereum/tests GeneralStateTests fixtures
that `test/fixtures/state_tests/skip.txt` skipped as too slow for the conformance
runner: the stQuadraticComplexityTest and stStaticCall 50,000-call and 50,000-return
loops, `static_Call1MB1024Calldepth`, and `VMTests/vmPerformance/loopMul`, a
10-million-iteration Solidity loop. It needs the ethereum-tests submodule. Their cases
run for seconds to minutes, too long for Benchee's repeated sampling, so the suite runs
each fixture's heaviest Prague case once, checks its post-state root, and prints gas
used, seconds, and Mgas/s. Cases that end in an exceptional halt burn their remaining
gas at once, so for those compare seconds, not Mgas/s. The BLAKE2F fixtures, also
skipped, measure the precompile instead
([#171](https://github.com/mw2000/eevm/issues/171)).

## Profiling

`bench/profile.exs` runs a 20k-iteration arithmetic loop for profiling:

```bash
MIX_ENV=prod mix profile.tprof --warmup --sort time bench/profile.exs
```

## Baseline

Measured at `c8e3c45` on an Amp orb: Intel Xeon @ 2.60 GHz, 4 vCPUs, Elixir 1.18.3,
OTP 27, `MIX_ENV=prod`. Expect about ±10% between runs on shared hardware.

### Interpreter

| Scenario | gas/run | ips | Mgas/s | Memory/run |
|---|---:|---:|---:|---:|
| compute: arithmetic loop (50k) | 2,700,006 | 2.28 | 6.15 | 754 MB |
| compute: jump loop (100k) | 2,600,003 | 2.74 | 7.12 | 621 MB |
| memory: MSTORE/MLOAD 32 KiB | 61,450 | 41.6 | 2.56 | 33.2 MB |
| memory: CALLDATACOPY+MCOPY+RETURN 32 KiB | 20,510 | 21.1 | 0.43 | 38.3 MB |
| keccak: 5k x 32 B | 395,006 | 17.1 | 6.75 | 81.2 MB |
| keccak: 64 KiB | 26,660 | 493 | 13.1 | 1.01 MB |
| storage: SSTORE/SLOAD 500 slots | 11,118,503 | 243 | 2,705 | 6.88 MB |
| calls: STATICCALL loop (2k) | 520,503 | 24.7 | 12.9 | 65.0 MB |
| erc20: transfer via Handler | 50,849 | 3,240 | 165 | 0.11 MB |

The storage scenario's Mgas/s is high because cold SSTOREs are priced for disk access,
which an in-memory database doesn't pay. Compare the compute scenarios with other EVMs.

### Precompiles

| Precompile | gas/run | ips | Mgas/s |
|---|---:|---:|---:|
| ecrecover (0x01) | 3,000 | 4,548 | 13.6 |
| sha256 1 KiB (0x02) | 444 | 573,514 | 255 |
| ripemd160 1 KiB (0x03) | 4,440 | 210,151 | 933 |
| identity 1 KiB (0x04) | 111 | 2,347,937 | 261 |
| modexp 2048-bit (0x05), before #188 | 698,368 | 145 | 101 |
| modexp 2048-bit (0x05) | 698,368 | 481 | 336 |
| bn256 add (0x06), before #182 | 150 | 11,597 | 1.74 |
| bn256 add (0x06) | 150 | 175,448 | 26.3 |
| bn256 mul (0x07), before #182 | 6,000 | 68.0 | 0.41 |
| bn256 mul (0x07) | 6,000 | 1,028 | 6.17 |
| bn256 pairing, 2 pairs (0x08), before #181 | 113,000 | 0.41 | 0.05 |
| bn256 pairing, 2 pairs (0x08) | 113,000 | 119 | 13.5 |
| blake2f 12 rounds (0x09) | 12 | 54,868 | 0.66 |
| blake2f 1M rounds (0x09) | 1,000,000 | 2.40 | 2.40 |
| bls12-381 pairing, 1 pair (0x0F) | 70,300 | 557 | 39.2 |

The BN256 and BLAKE2F rows were measured later, on the same kind of orb: after
[#169](https://github.com/mw2000/eevm/issues/169) and
[#171](https://github.com/mw2000/eevm/issues/171) were fixed, and before and after
[#181](https://github.com/mw2000/eevm/issues/181) and
[#182](https://github.com/mw2000/eevm/issues/182) replaced the `bn` library's pairing,
ecAdd, and ecMul with `EEVM.Precompiles.BN256.Curve`.

The ModExp job's random modulus is even. OpenSSL's `BN_mod_exp`, behind
`:crypto.mod_pow/3`, uses Montgomery multiplication only for odd moduli, so even ones
took about 7 ms against 2.1 ms for odd ones until
[#188](https://github.com/mw2000/eevm/issues/188) split them as q·2^k and recombined
the results by CRT. Odd moduli take the same path as before. A pure-Elixir
square-and-multiply was 3-9x slower than OpenSSL at 256-4096 bits.

### Hot spots

`tprof` on `bench/profile.exs` (320k opcodes) at the baseline attributed the time like
this:

| Share | Where | Why |
|---:|---|---|
| 10.8% | `MachineState.update_frame/2` | 920k calls, ~3 per opcode: gas, stack, and pc are each updated through a separate closure |
| 9.5% + 6.1% | `Interpreter.run_loop/1`, `execute_opcode/2` | The dispatch loop itself |
| ~8% | `EEVM.Interpreter.Instructions.Registry.info/1`, `String.Chars` | PUSH/DUP/SWAP metadata is rebuilt on every call, including `"PUSH#{n}"` name strings (180k `to_string` calls) |
| 6.6% | `ControlFlow.execute/2` | PUSH decodes its immediate through `bin_to_list` + `Enum.reduce` |
| ~7% | `Enum.at`, `Enum.slice`, `List.replace_at` | `Stack.peek/2` and `Stack.swap/2` walk the list through generic `Enum` |

The memory scenarios were dominated by `EEVM.Interpreter.Memory`, which stored one map
entry per byte ([#157](https://github.com/mw2000/eevm/issues/157)).

## After the first optimisations

The per-fork instruction table (`6d891f8`) took the Registry lookup off the hot path.
Two changes then addressed the other hot spots: cheaper PUSH decoding, direct frame
updates for gas and pc, and list-native stack peek/swap ("hot path" below); then memory
stored as 4 KiB binary chunks (#157). Measured back to back from the same base
commit (`339e0f0`), same machine and settings, ips at each step (expect ±10% noise
between runs):

| Scenario | 339e0f0 | hot path | chunked memory | Mgas/s | Memory/run |
|---|---:|---:|---:|---:|---:|
| compute: arithmetic loop (50k) | 2.80 | 3.11 | 2.90 | 7.57 → 7.83 | 637 → 586 MB |
| compute: jump loop (100k) | 3.31 | 3.90 | 3.65 | 8.61 → 9.48 | 518 → 462 MB |
| memory: MSTORE/MLOAD 32 KiB | 44.6 | 44.7 | 119 | 2.74 → 7.31 | 30.4 → 13.5 MB |
| memory: 1k MSTOREs over 1 MiB | 57.8 | 56.3 | 125 | 129 → 281 | 25.6 → 9.6 MB |
| memory: CALLDATACOPY+MCOPY+RETURN 32 KiB | 19.4 | 22.4 | 53,060 | 0.40 → 1,088 | 39.0 MB → 21 KB |
| keccak: 5k x 32 B | 19.6 | 21.3 | 25.1 | 7.73 → 9.91 | 71.0 → 54.7 MB |
| keccak: 64 KiB | 466 | 456 | 4,722 | 12.4 → 126 | 1.01 MB → 6.4 KB |
| storage: SSTORE/SLOAD 500 slots | 257 | 299 | 279 | 2,855 → 3,100 | 6.03 → 5.54 MB |
| calls: STATICCALL loop (2k) | 27.5 | 27.3 | 35.4 | 14.3 → 18.4 | 50.0 → 41.1 MB |
| erc20: transfer via Handler | 3,288 | 3,318 | 3,472 | 166 → 175 | 105 → 74 KB |

Precompiles are unchanged; they don't run through the interpreter.

### Slow state-test fixtures

`mix bench state_fixtures`, heaviest Prague case of each fixture, one run. Before is
`be1ad18`, capped at 120 s; after is `339e0f0` plus this series. `be1ad18` still
zero-filled a call's whole output area (fixed upstream in `85ed58a`), so
`static_Call50000_identity2` ran out of gas there; it passes now.

| Fixture | gas used | be1ad18 | after |
|---|---:|---:|---:|
| stQuadraticComplexityTest/Call50000 | 250,000,000 | 107 s | 0.75 s |
| stQuadraticComplexityTest/Call50000_identity2 | 250,000,000 | > 120 s | 0.11 s |
| stQuadraticComplexityTest/Callcode50000 | 250,000,000 | 106 s | 0.71 s |
| stQuadraticComplexityTest/QuadraticComplexitySolidity_CallDataCopy | 250,000,000 | > 120 s | 0.59 s |
| stQuadraticComplexityTest/Return50000 | 14,777,099 | > 120 s | 1.13 s |
| stQuadraticComplexityTest/Return50000_2 | 15,377,099 | > 120 s | 1.25 s |
| stStaticCall/static_Call1MB1024Calldepth | 855,137,385,770 | 0.18 s | < 0.01 s |
| stStaticCall/static_Call50000 | 5,014,061,098 | > 120 s | 1.06 s |
| stStaticCall/static_Call50000_ecrec | 39,058,598 | > 120 s | 0.79 s |
| stStaticCall/static_Call50000_identity | 86,895,919 | > 120 s | 0.79 s |
| stStaticCall/static_Call50000_identity2 | 92,280,716 | > 120 s | 0.82 s |
| stStaticCall/static_Call50000_rip160 | 3,863,696,700 | > 120 s | 0.83 s |
| stStaticCall/static_Return50000_2 | 15,273,928 | > 120 s | 1.40 s |
| stTimeConsuming/static_Call50000_sha256 | 954,878,498 | > 120 s | 3.06 s |
| VMTests/vmPerformance/loopMul | 2,470,045,378 | est. 345 s | 308 s |

Several cases end out of gas by design, which burns the remaining gas at once, so gas
used overstates the work done; compare seconds. The 50,000-call loops were slow because
every call copied its input and output through the byte-per-entry memory map; all their
cases now run in the conformance suite. loopMul barely got faster (7.3–8.2 Mgas/s before and
7.9–8.1 after at 100k iterations, from which its before time is estimated). It is a
tight Solidity loop, bounded by the dispatch loop itself, and stays skipped.

### Profile after the changes

On loopMul (20k iterations, 6.9M opcodes) the time is spread across the dispatch loop:
`run_loop/1` 15%, `ControlFlow.execute/2` 11%, `MachineState.consume_gas/2` 8%,
`execute_opcode/2` 7%, `current_opcode/1` + `:binary.at/2` 13%,
`MachineState.update_frame/2` 6% (the stack update most opcodes still make), and
`advance_pc` 7%. The compute loops still allocate about 770 bytes per opcode, because
each step rebuilds the frame and machine-state structs. The next gains need a
structural change, for example keeping pc, gas, and the stack in loop arguments instead
of the `MachineState` struct, and decoding the code once into a tuple.
