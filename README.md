# eevm

**Ethereum Virtual Machine implementation in Elixir.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19+-4B275F.svg)](https://elixir-lang.org)

A from-scratch EVM built for learning — both Ethereum internals and the Elixir language. Modules are documented with EVM concepts, EIP references, and idiomatic Elixir patterns side by side.

<p align="center">
  <img src="assets/banner.png" alt="eevm logo" />
</p>

## Usage

```elixir
# PUSH1 10, PUSH1 20, ADD, STOP
iex> EEVM.execute(<<0x60, 10, 0x60, 20, 0x01, 0x00>>) |> EEVM.stack_values()
[30]

# Disassemble raw bytecode
iex> EEVM.disassemble(<<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>)
[{0, "PUSH1", "0x01"}, {2, "PUSH1", "0x02"}, {4, "ADD", nil}, {5, "STOP", nil}]
```

## Supported Opcodes

| Category | Instructions |
|---|---|
| **Arithmetic** | `ADD` `MUL` `SUB` `DIV` `SDIV` `MOD` `SMOD` `ADDMOD` `MULMOD` `EXP` `SIGNEXTEND` |
| **Comparison** | `LT` `GT` `SLT` `SGT` `EQ` `ISZERO` |
| **Bitwise** | `AND` `OR` `XOR` `NOT` `BYTE` `SHL` `SHR` `SAR` |
| **Crypto** | `KECCAK256` |
| **Stack** | `POP` `PUSH0` `PUSH1`–`PUSH32` `DUP1`–`DUP16` `SWAP1`–`SWAP16` |
| **Memory** | `MLOAD` `MSTORE` `MSTORE8` `MSIZE` `MCOPY` |
| **Storage** | `SLOAD` `SSTORE` `TLOAD` `TSTORE` |
| **Environment** | `ADDRESS` `BALANCE` `ORIGIN` `CALLER` `CALLVALUE` `CALLDATALOAD` `CALLDATASIZE` `CALLDATACOPY` `CODESIZE` `GASPRICE` `RETURNDATASIZE` `RETURNDATACOPY` `BLOCKHASH` `COINBASE` `TIMESTAMP` `NUMBER` `PREVRANDAO` `GASLIMIT` `CHAINID` `SELFBALANCE` `BASEFEE` `BLOBBASEFEE` `BLOBHASH` `GAS` |
| **Control Flow** | `JUMP` `JUMPI` `JUMPDEST` `PC` |
| **Logging** | `LOG0` `LOG1` `LOG2` `LOG3` `LOG4` |
| **System** | `CREATE` `CREATE2` `CALL` `CALLCODE` `DELEGATECALL` `STATICCALL` `STOP` `RETURN` `REVERT` `INVALID` `SELFDESTRUCT` |
| **Precompiles** | ECRECOVER · SHA256 · RIPEMD160 · IDENTITY · MODEXP · BN256 Add/Mul/Pairing · BLAKE2F · KZG Point Eval |

## Architecture

```
lib/
├── eevm.ex                         # Public API — execute, disassemble, inspect
└── eevm/
    ├── executor.ex                  # Fetch-decode-execute loop (tail-recursive)
    ├── machine_state.ex             # Execution state (PC, stack, memory, gas, status)
    ├── stack.ex                     # LIFO stack (1024 depth, uint256 values)
    ├── memory.ex                    # Byte-addressable linear memory (sparse storage)
    ├── storage.ex                   # Persistent key-value storage (256-bit slots)
    ├── world_state.ex               # Account state (balances, code, nonces)
    ├── call_frame.ex                # Execution frame snapshot for nested calls
    ├── context/
    │   ├── transaction.ex           # Transaction context (origin, gasprice, blob_hashes)
    │   ├── block.ex                 # Block context (coinbase, timestamp, prevrandao, basefee)
    │   └── contract.ex              # Contract context (address, caller, value, calldata)
    ├── gas/
    │   ├── static.ex                # Fixed per-opcode costs (Yellow Paper Appendix G)
    │   ├── dynamic.ex               # Variable costs (EXP, KECCAK256, SSTORE, LOGn, CALL)
    │   ├── memory.ex                # Memory expansion cost (quadratic formula)
    │   └── access.ex                # Cold/warm access tracking (EIP-2929)
    ├── opcodes/
    │   ├── registry.ex              # Opcode byte → name + stack I/O metadata
    │   ├── helpers.ex               # Shared utilities (signed math, modular exp)
    │   ├── arithmetic.ex            # ADD, MUL, SUB, DIV, MOD, EXP, SIGNEXTEND
    │   ├── comparison.ex            # LT, GT, SLT, SGT, EQ, ISZERO
    │   ├── bitwise.ex               # AND, OR, XOR, NOT, BYTE, SHL, SHR, SAR
    │   ├── crypto.ex                # KECCAK256
    │   ├── control_flow.ex          # PUSH0–32, DUP1–16, SWAP1–16, JUMP, JUMPI, PC
    │   ├── logging.ex               # LOG0–LOG4
    │   ├── environment/
    │   │   ├── simple.ex            # ADDRESS, ORIGIN, CALLER, TIMESTAMP, GAS, ...
    │   │   ├── data.ex              # CALLDATALOAD, CALLDATACOPY, CODECOPY, RETURNDATACOPY
    │   │   └── external.ex          # BALANCE, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH
    │   ├── stack_memory_storage/
    │   │   ├── stack_ops.ex         # POP
    │   │   ├── memory_ops.ex        # MLOAD, MSTORE, MSTORE8, MSIZE, MCOPY
    │   │   └── storage_ops.ex       # SLOAD, SSTORE, TLOAD, TSTORE
    │   └── system/
    │       ├── termination.ex       # STOP, RETURN, REVERT, INVALID, SELFDESTRUCT
    │       └── creation.ex          # CREATE, CREATE2, CALL, DELEGATECALL, STATICCALL
    └── precompiles/
        ├── precompiles.ex           # Dispatcher (addresses 0x01–0x0A)
        ├── ecrecover.ex             # 0x01: EC signature recovery
        ├── sha256.ex                # 0x02: SHA-256 hash
        ├── ripemd160.ex             # 0x03: RIPEMD-160 hash
        ├── identity.ex              # 0x04: Data copy (no-op)
        ├── modexp.ex                # 0x05: Big integer modular exponentiation
        ├── bn256.ex                 # 0x06–0x08: BN256 curve operations
        ├── blake2f.ex               # 0x09: BLAKE2b compression
        └── kzg_point_eval.ex        # 0x0A: KZG point evaluation (EIP-4844)
```

The EVM is a **stack machine**. The executor reads one opcode at a time from bytecode and dispatches to the appropriate opcode module. Each module pops operands from the stack, computes, and pushes results back. All values are unsigned 256-bit integers. Memory is a separate byte-addressable space that expands on demand.

The architecture is intentionally flat — no processes, no GenServers, no OTP. Pure functions in, state out. This makes it easy to follow the execution flow and understand both the EVM and Elixir's functional style.

## Getting Started

```bash
# Clone
git clone https://github.com/mw2000/eevm.git && cd eevm

# Build
mix compile

# Test
mix test

# Interactive
iex -S mix
```

Requires Elixir 1.18+ and Erlang/OTP 28+.

## Official State Tests

This repo now includes an initial harness for `ethereum/tests` `GeneralStateTests` so you can compare `eevm` against the same fixture format other EVM implementations use.

```bash
# Fetch official GeneralStateTests fixtures into test/fixtures/state_tests/official/
python3 scripts/fetch_state_tests.py --clean

# Run only the StateTest harness
mix test test/state_test_test.exs
```

- Checked-in smoke fixtures live in `test/fixtures/state_tests/smoke/`.
- Imported official fixtures live in `test/fixtures/state_tests/official/`.
- Use `test/fixtures/state_tests/skip.txt` to temporarily skip known unsupported fixtures.
- Override discovery with `EEVM_STATE_TEST_GLOB` if you want to run only a subset.

## Elixir Concepts Covered

This project is designed as a learning tool. Each module demonstrates specific Elixir patterns:

- **Pattern matching** — Multi-clause functions, destructuring in function heads
- **Tagged tuples** — `{:ok, value}` / `{:error, reason}` for error handling
- **Structs** — Typed data structures with compile-time field guarantees
- **Recursion** — Tail-recursive execution loop (no mutable state anywhere)
- **Guards** — `when` clauses for type/range constraints
- **Bitwise operations** — Working with arbitrary-precision integers
- **Module attributes** — `@constants` and `@spec` type annotations
- **Binary pattern matching** — Parsing raw bytecode with `<<>>` syntax

## License

MIT
