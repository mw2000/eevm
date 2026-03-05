# eevm

**Ethereum Virtual Machine implementation in Elixir.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19+-4B275F.svg)](https://elixir-lang.org)

A from-scratch EVM built for learning — both Ethereum internals and the Elixir language. Every module is documented with EVM concepts and idiomatic Elixir patterns side by side.

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
| **Memory** | `MLOAD` `MSTORE` `MSTORE8` `MSIZE` |
| **Storage** | `SLOAD` `SSTORE` |
| **Environment** | `ADDRESS` `BALANCE` `ORIGIN` `CALLER` `CALLVALUE` `CALLDATALOAD` `CALLDATASIZE` `CALLDATACOPY` `CODESIZE` `GASPRICE` `RETURNDATASIZE` `BLOCKHASH` `COINBASE` `TIMESTAMP` `NUMBER` `PREVRANDAO` `GASLIMIT` `CHAINID` `SELFBALANCE` `BASEFEE` `GAS` |
| **Control Flow** | `JUMP` `JUMPI` `JUMPDEST` `PC` |
| **System** | `STOP` `RETURN` `REVERT` `INVALID` |

## Architecture

```
lib/
├── eevm.ex                    # Public API — execute, disassemble, inspect
└── eevm/
    ├── executor.ex            # Thin dispatcher — fetch, decode, route to opcode modules
    ├── machine_state.ex       # Execution state (PC, stack, memory, gas)
    ├── stack.ex               # LIFO stack (1024 depth, uint256 values)
    ├── memory.ex              # Byte-addressable linear memory
    ├── storage.ex             # Persistent key-value storage
    ├── gas.ex                 # Gas metering and per-opcode costs
    ├── opcodes.ex             # Opcode byte → name + stack metadata
    ├── context/
    │   ├── transaction.ex     # Transaction context (origin, gas price)
    │   ├── block.ex            # Block context (coinbase, timestamp, number)
    │   └── contract.ex         # Contract context (address, caller, value, calldata)
    └── opcodes/
        ├── helpers.ex         # Shared utilities (signing, modular exponentiation)
        ├── arithmetic.ex      # ADD, MUL, SUB, DIV, MOD, EXP, SIGNEXTEND
        ├── comparison.ex      # LT, GT, SLT, SGT, EQ, ISZERO
        ├── bitwise.ex         # AND, OR, XOR, NOT, BYTE, SHL, SHR, SAR
        ├── crypto.ex          # KECCAK256
        ├── stack_memory_storage.ex  # POP, MLOAD, MSTORE, SLOAD, SSTORE, MSIZE
        ├── environment.ex     # ADDRESS, CALLER, CALLVALUE, CALLDATALOAD, ...
        ├── control_flow.ex    # JUMP, JUMPI, PUSH0–PUSH32, DUP, SWAP
        └── system.ex          # STOP, RETURN, REVERT, INVALID
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

Requires Elixir 1.19+ and Erlang/OTP 28+.

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
