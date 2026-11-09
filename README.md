<p align="center">
  <img src="assets/banner.png" alt="eevm logo" />
</p>

# eevm

**An Ethereum Virtual Machine written in Elixir.**

[![CI](https://github.com/mw2000/eevm/actions/workflows/ci.yml/badge.svg)](https://github.com/mw2000/eevm/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.18+-4B275F.svg)](https://elixir-lang.org)

eevm executes EVM bytecode and Ethereum transactions in pure Elixir. It is its own
implementation, not a wrapper around revm, evmone, or another EVM. The only native
code is a small Rust NIF for BLS12-381 curve arithmetic (EIP-2537 precompiles).

It aims to be a production-grade EVM for the BEAM: easy to embed, easy to read,
and built from small, pure functions over immutable state. It includes the
interpreter, gas accounting, all precompiles through `0x11` plus P256VERIFY
(`0x100`), typed transactions, block processing, and Merkle-Patricia state roots.

> **Status:** eevm is under active development and does not yet pass the official
> Ethereum test suites. Do not use it where consensus correctness matters. See
> [Conformance](#conformance).

## Installation

eevm is not published on Hex yet. Add it from GitHub:

```elixir
def deps do
  [
    {:eevm, github: "mw2000/eevm"}
  ]
end
```

Requirements:

- Elixir 1.18 or later and Erlang/OTP 27 or later. CI tests Elixir 1.18 / OTP 27
  and Elixir 1.19 / OTP 28.
- A Rust toolchain (`cargo` and `rustc`, for example from [rustup](https://rustup.rs)).
  The BLS12-381 NIF in `native/eevm_bls` is compiled from source with
  [Rustler](https://github.com/rusterlium/rustler) when eevm compiles.
- A C compiler (`build-essential` on Debian/Ubuntu), used by the `blst` crate.

## Quick start

### Execute bytecode

```elixir
# PUSH1 10, PUSH1 20, ADD, STOP
iex> EEVM.execute(<<0x60, 10, 0x60, 20, 0x01, 0x00>>) |> EEVM.stack_values()
[30]

# PUSH1 42, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
iex> state = EEVM.execute(<<0x60, 42, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xF3>>, gas: 100_000)
iex> :binary.decode_unsigned(state.frame.return_data)
42
iex> 100_000 - state.frame.gas
18

iex> EEVM.disassemble(<<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>)
[{0, "PUSH1", "0x01"}, {2, "PUSH1", "0x02"}, {4, "ADD", nil}, {5, "STOP", nil}]
```

`EEVM.trace/2` runs the same code with an opcode-level tracer, and
`EEVM.Tracer.to_json/1` renders it in the EIP-3155 format that geth and other
clients use, so traces can be diffed against them.

### Execute a transaction

`EEVM.Handler.execute/4` runs a signed transaction end to end: decode, recover
the sender, validate, charge gas, execute, refund, and pay the coinbase. It
returns `{:ok, %EEVM.TransactionResult{}}` for any transaction that passes
validation, including reverted ones, and `{:error, reason}` otherwise.

```elixir
alias EEVM.Context.Block
alias EEVM.Database
alias EEVM.Database.InMemory
alias EEVM.Transaction.{FeeMarket, Signer}

private_key = <<0x46::256>>
{:ok, <<4, public_key::binary-size(64)>>} = ExSecp256k1.create_public_key(private_key)
<<_::binary-size(12), sender::unsigned-big-160>> = ExKeccak.hash_256(public_key)
recipient = 0xB0B

db = InMemory.new(accounts: %{sender => %{balance: 10 ** 18, nonce: 0, code: <<>>}})
block = Block.new(number: 1, gaslimit: 30_000_000, basefee: 7, coinbase: 0xC0FFEE)

tx = %FeeMarket{
  chain_id: 1,
  nonce: 0,
  max_priority_fee_per_gas: 1,
  max_fee_per_gas: 10,
  gas_limit: 21_000,
  to: <<recipient::160>>,
  value: 1_000,
  data: <<>>,
  access_list: []
}

{:ok, {<<r::256, s::256>>, y_parity}} =
  ExSecp256k1.sign_compact(Signer.signing_hash(tx, 1), private_key)

{:ok, result} =
  EEVM.Handler.execute(%{tx | y_parity: y_parity, r: r, s: s}, block, db, hardfork: :cancun)

result.status
#=> :success
result.gas_used
#=> 21000
Database.get_balance(result.post_state_db, recipient)
#=> 1000
EEVM.StateRoot.compute_state_root(result.post_state_db) |> Base.encode16(case: :lower)
#=> "7b838becc60c5d28adc4a332cd44cf603b4ef0e590f50a268de2457cbc78fa09"
```

Addresses are integers in the database API and 20-byte binaries in transaction
structs, matching their wire encoding. `EEVM.Handler.execute/4` also accepts raw
signed transaction bytes.

### Build, encode, and execute a block

`EEVM.Block` handles whole blocks. `build/4` produces a child of a parent
header: it derives the base fee and blob fields, runs the transactions, and
fills in every root. `encode/1` and `decode/1` convert to and from canonical
RLP. `execute/4` validates a block against its parent (including the EIP-7934
size limit from Osaka), applies the system calls, transactions, and
withdrawals, and checks the header's commitments. Both take the same
`:hardfork` and `:config` options as `EEVM.Handler.execute/4`, and errors are
listed in `EEVM.Error`.

```elixir
iex> alias EEVM.Block
iex> alias EEVM.Transaction.{FeeMarket, Signer}
iex> private_key = <<0x46::256>>
iex> {:ok, <<4, public_key::binary-size(64)>>} = ExSecp256k1.create_public_key(private_key)
iex> <<_::binary-size(12), sender::unsigned-big-160>> = ExKeccak.hash_256(public_key)
iex> db = EEVM.Database.InMemory.new(accounts: %{sender => %{balance: 10 ** 18, nonce: 0, code: <<>>}})
iex> tx = %FeeMarket{chain_id: 1, nonce: 0, max_priority_fee_per_gas: 1, max_fee_per_gas: 10,
...>   gas_limit: 21_000, to: <<0xB0B::160>>, value: 1_000, data: <<>>, access_list: []}
iex> {:ok, {<<r::256, s::256>>, y_parity}} = ExSecp256k1.sign_compact(Signer.signing_hash(tx, 1), private_key)
iex> parent = EEVM.Block.Header.new(gas_limit: 30_000_000, base_fee_per_gas: 7, hash: <<1::256>>)
iex> {:ok, block, _result} = Block.build(parent, [%{tx | y_parity: y_parity, r: r, s: s}], db, timestamp: 12)
iex> {:ok, decoded} = block |> Block.encode() |> Block.decode()
iex> {:ok, result} = Block.execute(decoded, parent, db, hardfork: :cancun)
iex> {result.gas_used, EEVM.Database.get_balance(result.post_state_db, 0xB0B)}
{21000, 1000}
```

`EEVM.Block.Processor.process_block/4` is the lower-level engine underneath; use
it directly to plug in your own transaction executor.

State lives behind the `EEVM.Database` behaviour. `EEVM.Database.InMemory` is the
built-in backend; implement the behaviour to execute against your own storage.

## Hardforks and EIPs

Pick the rules with the `:hardfork` option (default `:cancun`). `EEVM.HardforkConfig`
knows every fork from `:frontier` to `:osaka`.

Cancun is the primary target. Before Cancun, only some rules change with the
configured fork. Static opcode gas, opcodes added before Shanghai (such as
REVERT, CREATE2, and CHAINID), and several older EIPs (such as EIP-150 and
EIP-2200) are not yet gated per fork, so older forks run with mostly post-Berlin
rules.

Rules that do switch on the configured fork: EIP-170, EIP-2929, EIP-3529,
EIP-3541, EIP-3855, EIP-3860, EIP-1153, EIP-5656, EIP-6780, EIP-4788, EIP-2537,
EIP-2935, EIP-7623, EIP-7823, EIP-7825, EIP-7883, EIP-7918, EIP-7934, EIP-7939,
and EIP-7951.

| Area | Implemented |
|------|-------------|
| Transactions | Legacy with EIP-155, EIP-2718 envelopes, EIP-2930 access lists, EIP-1559 fee market, EIP-4844 blobs, EIP-7702 set code (partial, see [#144](https://github.com/mw2000/eevm/issues/144)), EIP-7623 calldata floor, EIP-7825 gas limit cap |
| Execution and gas | Full opcode set through Cancun (including PUSH0, TLOAD/TSTORE, MCOPY, BLOBHASH, BLOBBASEFEE), EIP-2929 warm/cold access, EIP-2200 and EIP-3529 SSTORE metering and refunds, EIP-161, EIP-170, EIP-3541, EIP-3651, EIP-3860, EIP-6780 |
| Precompiles | `0x01`–`0x11` and `0x100`: ECRECOVER, SHA256, RIPEMD160, IDENTITY, MODEXP (EIP-198, EIP-2565; EIP-7823 and EIP-7883 from Osaka), alt_bn128 (EIP-196/197), BLAKE2F (EIP-152), KZG point evaluation (EIP-4844), BLS12-381 (EIP-2537), P256VERIFY (EIP-7951, from Osaka) |
| Blocks | RLP block codec, building, header and body validation, EIP-7934 size limit, EIP-4895 withdrawals, EIP-4788 beacon roots, EIP-2935 block hashes, receipts, logs bloom, MPT state, transaction, and receipt roots |
| Tooling | EIP-3155 tracing, disassembler, custom precompile registration |

Osaka support (so far the CLZ opcode, EIP-7823, EIP-7825, EIP-7883, EIP-7918,
EIP-7934, and EIP-7951) is in progress. The
[roadmap](https://github.com/mw2000/eevm/issues/153) tracks what remains.

## Conformance

eevm is not yet conformant with the official
[`ethereum/tests`](https://github.com/ethereum/tests) suites; many official
fixtures still fail. Two Mix tasks run the `GeneralStateTests` and
`BlockchainTests` fixtures from a pinned submodule and print pass, fail, and
crash counts by fork and by test category. Each case runs in its own process
with a heap cap and a timeout, so a runaway case counts as a crash instead of
stopping the run. The default `mix test` run covers unit tests, spec-derived
test vectors, and small checked-in smoke fixtures, not the official suites.

```bash
git submodule update --init --depth 1 test/fixtures/state_tests/ethereum-tests

mix eevm.state_tests
mix eevm.state_tests 'test/fixtures/state_tests/ethereum-tests/GeneralStateTests/stExample/*.json'
mix eevm.blockchain_tests 'test/fixtures/state_tests/ethereum-tests/BlockchainTests/ValidBlocks/**/*.json'
```

CI runs both suites against `test/fixtures/*/known_failures.txt` and fails only
when a case outside those lists fails. After fixing failures, regenerate a list
with `--write-known-failures FILE`. `test/fixtures/*/skip.txt` lists the few
fixtures that are not run at all because they abort the VM.

## Performance

`mix bench` runs a Benchee suite of interpreter workloads (compute loops, memory,
Keccak, storage, calls, an ERC-20 transfer) and precompiles, and prints gas/s for each.
[bench/README.md](bench/README.md) describes the workloads and lists baseline numbers
and profiling results.

## Architecture

eevm is layered like revm:

- **Interpreter** (`EEVM.Interpreter`): the fetch-decode-execute loop over an
  immutable `MachineState`. Opcode metadata lives in
  `EEVM.Interpreter.Instructions.Registry` and the semantics in
  `EEVM.Interpreter.Instructions.*`.
- **Handler** (`EEVM.Handler`): one transaction through validation,
  pre-execution, execution, and post-execution.
- **Block** (`EEVM.Block`): RLP codec, validation, and execution of a whole
  block: system calls, transactions through the handler, withdrawals,
  receipts, and roots.

The [API documentation](https://mw2000.github.io/eevm/) is built with ExDoc from
`main`; its [`EEVM` module page](https://mw2000.github.io/eevm/EEVM.html) has the
module map. Run `mix docs` to build it locally. HexDocs will follow once the
package is published on Hex.

## Contributing

Read [AGENTS.md](https://github.com/mw2000/eevm/blob/main/AGENTS.md) first. It covers the code conventions, where things
live, the checks CI runs, and the workflow. Open tasks are in
[GitHub Issues](https://github.com/mw2000/eevm/issues).

```bash
git clone https://github.com/mw2000/eevm.git && cd eevm
mix deps.get
mix test
```

## License

[MIT](LICENSE)
