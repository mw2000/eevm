<p align="center">
  <img src="assets/banner.png" alt="eevm logo" />
</p>

# eevm

**Ethereum Virtual Machine implementation in Elixir.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19+-4B275F.svg)](https://elixir-lang.org)

A from-scratch EVM built for learning — both Ethereum internals and the Elixir language. Implements the full execution engine with hardfork-aware gas, all precompiles, transaction processing, and an MPT-backed state root — verified against the official `ethereum/tests` suite.

## Getting Started

```bash
git clone https://github.com/mw2000/eevm.git && cd eevm
mix compile
mix test
iex -S mix
```

Requires Elixir 1.18+ and Erlang/OTP 28+.

## Usage

```elixir
# Execute raw bytecode: PUSH1 10, PUSH1 20, ADD, STOP
iex> EEVM.execute(<<0x60, 10, 0x60, 20, 0x01, 0x00>>) |> EEVM.stack_values()
[30]

# Disassemble
iex> EEVM.disassemble(<<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>)
[{0, "PUSH1", "0x01"}, {2, "PUSH1", "0x02"}, {4, "ADD", nil}, {5, "STOP", nil}]
```

## Official State Tests

The repo includes a harness for `ethereum/tests` `GeneralStateTests`, the same fixture format used by other EVM implementations.

```bash
# Initialize the pinned ethereum/tests submodule
git submodule update --init test/fixtures/state_tests/ethereum-tests

# Run the checked-in smoke fixture
mix test test/state_test_test.exs

# Run a focused official subset
EEVM_STATE_TEST_GLOB='test/fixtures/state_tests/ethereum-tests/GeneralStateTests/stExample/*.json' \
  mix test test/state_test_test.exs
```

- Smoke fixtures live in `test/fixtures/state_tests/smoke/`.
- Official fixtures are in the `ethereum-tests` submodule at a pinned snapshot.
- Add entries to `test/fixtures/state_tests/skip.txt` to skip known unsupported cases.
- The default glob runs smoke only; use `EEVM_STATE_TEST_GLOB` to target official folders.

## License

MIT
