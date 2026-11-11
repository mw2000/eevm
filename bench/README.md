# Benchmarks

eevm's benchmark suite uses [Benchee](https://github.com/bencheeorg/benchee). Run it
from the repository root:

```bash
mix bench                  # every suite in bench/*_bench.exs except state_fixtures
mix bench interpreter      # only bench/interpreter_bench.exs
mix bench precompiles      # only bench/precompiles_bench.exs
mix bench ecdsa            # only bench/ecdsa_bench.exs
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
| calls: CALL 100 distinct 24 KB contracts that STOP | 100 CALLs, each to a different contract of the EIP-170 maximum size that stops at its first byte |
| calls: CALL 100 distinct 24 KB contracts that JUMP once | The same, but each contract first jumps to a JUMPDEST at its end |
| erc20: transfer via Handler | A signed legacy `transfer(address,uint256)` with two SLOAD/SSTOREs and a LOG3 |

`bench/precompiles_bench.exs` calls `EEVM.Precompiles.execute/4` directly with valid
inputs: ecrecover, sha256, ripemd160, and identity (1 KiB), a 2048-bit ModExp, BN256
ecAdd, ecMul with a random 256-bit scalar, a two-pair BN256 pairing, BLAKE2F at 12 and 1M rounds, KZG
point evaluation, and every BLS12-381 precompile: G1/G2 ADD, MSM with 1 and 128 pairs,
1- and 2-pair pairings, and both maps to the curve.

`bench/ecdsa_bench.exs` times `EEVM.Crypto.ECDSA` on its own: secp256k1 recovery
(ECRECOVER and every signed transaction), secp256k1 signing, and P-256 verification,
plus the P256VERIFY precompile (`0x100`), which is Osaka-only and so not in the
precompiles suite.

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

## The decoded program

[#208](https://github.com/mw2000/eevm/issues/208) took the rest of the dispatch cost out
of the loop. `EEVM.Interpreter.InstructionTable.decode/3` turns a contract's code into
a program once per transaction: a tuple with one instruction per code byte, PUSH values
already read, PUSH data marked so jumps cannot land in it, and PUSH+JUMP(I) pairs fused
into one instruction. The loop fetches `elem(program, pc)`, checks gas and stack bounds
from the instruction, and dispatches on its opcode. Traced runs decode a program whose
instructions are wrapped for the tracer, so untraced runs make no tracer check.

Two details of the loop's shape carried most of the gain, both measured on loopMul:
matching the instruction in a `case` inside `loop/6` rather than in a separate function
head (a 3x difference), and giving `step/8` the loop's own arguments first so the calls
between them move no registers (12%). Fusing PUSH+JUMP(I) adds 2-5%.

`mix bench interpreter`, `d0164ce` against the series, run alternately twice each on the
same orb, `MIX_ENV=prod`. Mgas/s is the mean of the two runs. The baseline's ERC-20 and
keccak rows are lower than in the table above because Keccak-256 and ECDSA became pure
Elixir in between.

| Scenario | Mgas/s before | Mgas/s after | Speedup | Memory/run |
|---|---:|---:|---:|---:|
| compute: arithmetic loop (50k) | 54.6 | 152 | 2.8x | 88.1 → 11.5 MB |
| compute: jump loop (100k) | 64.7 | 202 | 3.1x | 67.1 → 7.63 MB |
| memory: MSTORE/MLOAD 32 KiB | 20.5 | 27.4 | 1.3x | 4.94 → 3.37 MB |
| memory: 1k MSTOREs over 1 MiB | 814 | 1,065 | 1.3x | 3.11 → 2.06 MB |
| memory: CALLDATACOPY+MCOPY+RETURN 32 KiB | 1,251 | 1,236 | 1.0x | 17.1 → 17.7 KB |
| keccak: 5k x 32 B | 6.26 | 6.45 | 1.0x | 27.4 → 21.3 MB |
| keccak: 64 KiB | 6.01 | 6.00 | 1.0x | 0.23 → 0.23 MB |
| storage: SSTORE/SLOAD 500 slots | 5,132 | 6,069 | 1.2x | 2.81 → 2.30 MB |
| calls: STATICCALL loop (2k) | 28.8 | 33.7 | 1.2x | 27.4 → 24.3 MB |
| erc20: transfer via Handler | 33.9 | 34.7 | 1.0x | 110 → 110 KB |

The compute loops now allocate about two words per opcode, the stack's new cons cell,
down from about 110 bytes.

loopMul's heaviest case (`loopMul@prague:d1g0v0`) takes 36 s on its own in
`mix eevm.state_tests --jobs 1`, down from 142 s, and 38 s in the full GeneralStateTests
run, so it is off the skip list.

Decoding is not free. A program for 24 KB of code takes about 0.5 ms to build, and the
garbage collector copies the new tuple until it is promoted, where #187's JUMPDEST
analysis took about 0.3 ms on a frame's first jump. A contract that loops pays that back
quickly, but a short run of a large contract now costs up to about 0.9 ms more per
transaction ([#210](https://github.com/mw2000/eevm/issues/210)). Times for
`EEVM.Interpreter.run/2` on loopMul's contract, alone and copied to 24 KB,
`MIX_ENV=prod`, median of 51 runs, averaged over separate runs:

| Run | d0164ce | after |
|---|---:|---:|
| 1 KB contract, 1 loop iteration | 66 µs | 62 µs |
| 1 KB contract, 100 loop iterations | 1,266 µs | 443 µs |
| 24 KB contract, 1 loop iteration | 359 µs | 1,225 µs |
| 24 KB contract that STOPs at once | 6 µs | 557 µs |

## Decoding only code that loops

[#210](https://github.com/mw2000/eevm/issues/210) removed that cost. A frame now decodes
its code only once decoding pays for itself. Until then it runs the code undecoded: the
loop reads each instruction straight from the bytes
(`EEVM.Interpreter.InstructionTable.fetch/3`), at about 50 Mgas/s against 170 decoded,
and checks jumps against the code's JUMPDEST map, which takes about a sixth of the time
decoding does to build. The first jump after the frame has used 3 gas per code byte decodes the
code. By then, running undecoded has cost about as much extra time as decoding would, so
either way a frame spends at most about twice what the better choice would have, and the
time decoding can add stays below about 12 ns per gas. The gas paid to reach the code
counts too: 21,000 for a transaction's own code, and 2,600 (a cold account, EIP-2929) for
a callee's. So a transaction's code up to about 7 KB and a callee's up to about 870 bytes
still decode at once.

The JUMPDEST map also got 2.5x faster on Solidity code: it now grows at each JUMPDEST
rather than once per byte.

`EEVM.Interpreter.run/2` on the same contracts as above, plus 24 KB of code that jumps
once, to a JUMPDEST at its end. `MIX_ENV=prod`, median of 201 runs (501 to 1,001 for the
1 KB rows, each in a fresh process):

| Run | d0164ce | cdbd45d (#208) | after |
|---|---:|---:|---:|
| 1 KB contract, 1 loop iteration | 62 µs | 48 µs | 54 µs |
| 1 KB contract, 100 loop iterations | 1,267 µs | 445 µs | 446 µs |
| 24 KB contract, 1 loop iteration | 353 µs | 1,170 µs | 215 µs |
| 24 KB contract that STOPs at once | 5 µs | 530 µs | 6 µs |
| 24 KB contract that jumps once | 262 µs | 1,299 µs | 110 µs |

`mix bench interpreter`, `cdbd45d` against this change, `MIX_ENV=prod`, Mgas/s as the
mean of six runs before and two after:

| Scenario | Mgas/s before | Mgas/s after | Speedup | Memory/run |
|---|---:|---:|---:|---:|
| calls: CALL 100 distinct 24 KB contracts that STOP | 0.65 | 228 | 349x | 150 → 1.0 MB |
| calls: CALL 100 distinct 24 KB contracts that JUMP once | 0.62 | 18.3 | 30x | 150 → 1.1 MB |

Every other scenario, and its memory per run, is unchanged within the ±5% these runs vary
by. With 100 decoded 24 KB programs alive at once, `cdbd45d` spent most of each call
copying them in the garbage collector, about 4 ms per call that stops at once. Now such a
call takes about 12 µs, and one that jumps once about 150 µs, most of it building the
JUMPDEST map.

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

## Faster pure-Elixir ECDSA

[#197](https://github.com/mw2000/eevm/issues/197) replaced `ex_secp256k1` and
`:crypto.verify/5` with `EEVM.Crypto.ECDSA`, and recovering a transaction sender went
from about 0.2-0.35 ms to 1.2 ms.
[#209](https://github.com/mw2000/eevm/issues/209) cuts the number of field operations
per scalar multiplication:

- GLV on secp256k1: the endomorphism φ(x, y) = (β·x, y) = λ·P splits each 256-bit
  scalar into two halves of about 128 bits, so the doubling chain is half as long.
- Width-w NAF: signed odd digits, so about one bit in six (w = 5) or nine (w = 8)
  costs an addition, and tables hold only odd multiples.
- A compile-time table of the base point's odd multiples G … 127G (and their φ
  images), with Z = 1, so each addition uses the cheaper mixed formula.
- Shamir's trick, as before: `u₁·G + u₂·Q` (up to four GLV halves) shares one
  doubling chain.
- P-256's a = −3 doubling, 3(X − Z²)(X + Z²), and a 4-bit window for the
  square root in recovery.

Before (`2e1bedf`) and after (the same base plus this change, so before the
interpreter work that follows `2e1bedf`), same orb, `MIX_ENV=prod`, two alternating
rounds each
(`mix bench ecdsa` and `mix bench interpreter`). ips are calls per second; native is
`ex_secp256k1` or `:crypto` as #197 measured it.

| Workload | native | before | after | after / before |
|---|---:|---:|---:|---:|
| secp256k1 recover | 0.18-0.35 ms | 1.27 / 1.19 ms | 0.71 / 0.73 ms | 1.7× |
| secp256k1 sign | 0.18-0.25 ms | 0.97 / 0.92 ms | 0.48 / 0.54 ms | 1.9× |
| P-256 verify | 0.10-0.17 ms | 1.14 / 1.15 ms | 0.86 / 0.86 ms | 1.3× |
| ecrecover (0x01) | 2,704 / 4,792 ips | 730 / 748 ips | 1,336 / 1,358 ips | 1.8× |
| p256verify (0x100) | | 924 / 926 ips | 1,230 / 1,193 ips | 1.3× |
| erc20: transfer via Handler | 3,220 / 1,595 ips | 633 / 667 ips | 1,070 / 951 ips | 1.55× |

Recovery stays 2-4× slower than libsecp256k1. P-256 gains least: it has no
endomorphism, so its doubling chain stays 256 long. The six conformance ratchets went
from 767 s to 705 s on the orb, mostly in the blockchain suites, which recover one
sender per transaction (EEST blockchain 259 → 232 s, Osaka blockchain 283 → 251 s).
Before #197 they took about 597 s on the same orb, so this wins back about a third
of the 170 s that pure-Elixir recovery added.

Tried and not kept: a special-form reduction for p = 2²⁵⁶ − 0x1000003D1 was no faster
than `rem/2` on the bignum product (#209), and the profile now splits mostly between
`double/2` (about 23%) and `add/3` (about 28%), each a handful of 256-bit `rem` calls.
