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
ecAdd, ecMul with a random 256-bit scalar, a two-pair BN256 pairing, BLAKE2F at 12 and 1M rounds, KZG
point evaluation, and every BLS12-381 precompile: G1/G2 ADD, MSM with 1 and 128 pairs,
1- and 2-pair pairings, and both maps to the curve.

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

## The register loop

[#193](https://github.com/mw2000/eevm/issues/193) made that structural change.
`EEVM.Interpreter`'s loop keeps pc, gas, and the stack (a list) in its own
arguments and writes them back into the frame only when an opcode needs the whole
`MachineState`: calls, storage, memory, logs, halts. Pure stack opcodes and
PUSH, DUP, SWAP, JUMP, JUMPI, PC, GAS, and JUMPDEST never touch the structs. Three
smaller changes followed the profile: one list pattern per DUPn and SWAPn instead
of `:lists.nth/2` and `:lists.split/2`, and a gas register kept below 2^59, so
the 2^63 - 1 gas that state tests give a transaction no longer makes every
subtraction allocate a bignum.

`mix bench interpreter`, `f35ac13` against the four #193 commits on top of it,
run alternately twice each on the same orb. Mgas/s is the mean of the two runs.

| Scenario | Mgas/s before | Mgas/s after | Speedup | Memory/run |
|---|---:|---:|---:|---:|
| compute: arithmetic loop (50k) | 8.71 | 56.1 | 6.4x | 588 → 88.1 MB |
| compute: jump loop (100k) | 9.74 | 65.1 | 6.7x | 482 → 67.1 MB |
| memory: MSTORE/MLOAD 32 KiB | 7.06 | 19.7 | 2.8x | 13.9 → 4.94 MB |
| memory: 1k MSTOREs over 1 MiB | 279 | 716 | 2.6x | 9.88 → 3.11 MB |
| memory: CALLDATACOPY+MCOPY+RETURN 32 KiB | 1,116 | 1,254 | 1.1x | 20.8 → 17.1 KB |
| keccak: 5k x 32 B | 10.7 | 21.1 | 2.0x | 56.0 → 22.6 MB |
| keccak: 64 KiB | 122 | 123 | 1.0x | 6.6 → 6.1 KB |
| storage: SSTORE/SLOAD 500 slots | 2,846 | 5,280 | 1.9x | 5.77 → 2.81 MB |
| calls: STATICCALL loop (2k) | 17.9 | 26.1 | 1.5x | 43.1 → 27.1 MB |
| erc20: transfer via Handler | 165 | 169 | 1.0x | 83 → 65 KB |

The compute loops now allocate about 110 bytes per opcode, down from about 735: the
new stack cell and, for JUMP and JUMPI, the result tuple of the JUMPDEST check.
keccak 64 KiB and the ERC-20 transfer are dominated by hashing and transaction
setup, which this did not touch.

loopMul's heaviest case (`loopMul@prague:d1g0v0`, about 1.9 billion opcodes) takes
142 s in `mix eevm.state_tests`, down from 308 s. That is still past the 60 s the skip
list allows and too close to CI's 180 s per-case timeout, so it stays skipped
([#208](https://github.com/mw2000/eevm/issues/208)). What remains is the dispatch
itself: `loop/7` and `step/8` take 60% of its time under tprof, and the tracer hook's
call another 16%.

## Pure-Elixir BLS12-381, KZG, and ModExp

[#199](https://github.com/mw2000/eevm/issues/199) replaced the last native code in the
precompiles. The `eevm_bls` Rust NIF (`bls12_381_plus` and `blst`) backed the EIP-2537
precompiles and KZG point evaluation, and OpenSSL's `:crypto.mod_pow/3` backed ModExp.
Both are now Elixir: `EEVM.Precompiles.Bls12381.Curve` and a fixed-window
square-and-multiply. Before the NIF was deleted, a scratch script ran each workload
through both implementations: same inputs (random points and scalars from a fixed
seed, c-kzg-4844's `correct_proof_2_2` for KZG), the same orb, `MIX_ENV=prod`, and
Osaka gas. "native" is the NIF (or the previous `:crypto` ModExp); ips are
calls per second.

| Precompile | gas | native ips | native Mgas/s | Elixir ips | Elixir Mgas/s | Elixir / native |
|---|---:|---:|---:|---:|---:|---:|
| kzg point evaluation (0x0A) | 50,000 | 186 | 9.32 | 59.9 | 2.99 | 0.32× |
| g1add (0x0B) | 375 | 21,707 | 8.14 | 12,860 | 4.82 | 0.59× |
| g1msm, 1 pair (0x0C) | 12,000 | 1,783 | 21.4 | 429 | 5.15 | 0.24× |
| g1msm, 2 pairs (0x0C) | 22,776 | 932 | 21.2 | 208 | 4.74 | 0.22× |
| g1msm, 8 pairs (0x0C) | 69,888 | 243 | 17.0 | 72.6 | 5.07 | 0.30× |
| g1msm, 32 pairs (0x0C) | 240,768 | 59.4 | 14.3 | 21.1 | 5.09 | 0.36× |
| g1msm, 128 pairs (0x0C) | 797,184 | 15.0 | 11.9 | 7.10 | 5.66 | 0.47× |
| g2add (0x0D) | 600 | 18,084 | 10.9 | 10,227 | 6.14 | 0.57× |
| g2msm, 1 pair (0x0E) | 22,500 | 661 | 14.9 | 235 | 5.29 | 0.36× |
| g2msm, 2 pairs (0x0E) | 45,000 | 330 | 14.8 | 97.8 | 4.40 | 0.30× |
| g2msm, 8 pairs (0x0E) | 143,280 | 85.9 | 12.3 | 34.9 | 5.00 | 0.41× |
| g2msm, 32 pairs (0x0E) | 465,120 | 22.0 | 10.2 | 11.1 | 5.15 | 0.50× |
| g2msm, 128 pairs (0x0E) | 1,509,120 | 5.42 | 8.18 | 3.65 | 5.51 | 0.67× |
| pairing, 1 pair (0x0F) | 70,300 | 568 | 39.9 | 91.2 | 6.41 | 0.16× |
| pairing, 2 pairs (0x0F) | 102,900 | 285 | 29.3 | 65.3 | 6.72 | 0.23× |
| pairing, 8 pairs (0x0F) | 298,500 | 69.0 | 20.6 | 25.2 | 7.53 | 0.37× |
| map fp to g1 (0x10) | 5,500 | 15,766 | 86.7 | 1,193 | 6.56 | 0.08× |
| map fp2 to g2 (0x11) | 23,800 | 4,984 | 119 | 376 | 8.94 | 0.08× |
| modexp 2048-bit, even modulus (0x05) | 7,862,272 | 484 | 3,807 | 87.2 | 685 | 0.18× |
| modexp 2048-bit, odd modulus (0x05) | 7,862,272 | 466 | 3,666 | 68.7 | 540 | 0.15× |
| modexp 4096-bit, odd modulus (0x05) | 65,003,520 | 65.6 | 4,261 | 11.0 | 714 | 0.17× |
| modexp 256-bit, odd modulus (0x05) | 4,080 | 33,116 | 135 | 10,829 | 44.2 | 0.33× |

Every EIP-2537 workload runs at 4.4-9 Mgas/s in Elixir, about the interpreter's own
throughput on compute loops before #193 (6-9 Mgas/s, above), so no input to those precompiles is
much cheaper per gas than ordinary bytecode, though all are slower than native. KZG
point evaluation is the lowest at 3.0 Mgas/s, and the native version (9.3 Mgas/s) was
lowest too: of its 16.7 ms, the two-pair pairing check takes 12.7 ms (about 6.5 ms of
final exponentiation and 3.1 ms of Miller loop per pair), the three-term MSM 2.6 ms,
and decompression and the two subgroup checks about 1.8 ms.

The furthest below native are:

- map-to-curve (0.08×; blst's SSWU and square roots are heavily optimised);
- the one-pair pairing (0.16×);
- single-point G1 MSM (0.24×);
- KZG (0.32×).

Large MSMs come closest (0.5-0.7×), because Pippenger's bucket method amortises the
work. ModExp drops to 0.15-0.33× of OpenSSL but stays far above the interpreter's
Mgas/s. The NIF itself was not native-fast: `bls12_381_plus` multiplies with
constant-time double-and-add, so a G1 multiplication took 0.56 ms.

`mix bench precompiles` now includes the BLS12-381 and KZG workloads.
