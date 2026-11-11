<p align="center">
  <img src="assets/banner.png" alt="eevm logo" />
</p>

# eevm

**An Ethereum Virtual Machine written in Elixir.**

[![CI](https://github.com/mw2000/eevm/actions/workflows/ci.yml/badge.svg)](https://github.com/mw2000/eevm/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.18+-4B275F.svg)](https://elixir-lang.org)

eevm executes EVM bytecode and Ethereum transactions in pure Elixir. It is its own
implementation, not a wrapper around revm, evmone, or another EVM, and its
cryptography is Elixir too: Keccak-256, SHA-256, RIPEMD-160, BLAKE2F, ModExp,
ECDSA over secp256k1 and P-256, the BN254 and BLS12-381 curves, and KZG. eevm
has no native code of any kind, no NIFs and no OTP `:crypto`, so it could in
theory run on bare metal.

It aims to be a production-grade EVM for the BEAM: easy to embed, easy to read,
and built from small, pure functions over immutable state. It includes the
interpreter, gas accounting, all precompiles through `0x11` plus P256VERIFY
(`0x100`), typed transactions, block processing, and Merkle-Patricia state roots.

> **Status:** eevm is under active development and does not yet pass the official
> Ethereum test suites. Do not use it where consensus correctness matters. See
> [Conformance](#conformance).

## Installation

eevm is not published on Hex yet. Add it from GitHub:

<!-- docs-check: skip -->
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

## Quick start

### Run bytecode

`EEVM.run/2` runs code as a message call with no transaction rules, which suits
tests and `eth_call`-style probes. It returns `{:ok, %EEVM.CallResult{}}` with a
`status` of `:success`, `:revert`, or `{:halt, reason}`.

```elixir
# PUSH1 42, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
iex> {:ok, result} = EEVM.run(<<0x60, 42, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xF3>>, gas: 100_000)
iex> {result.status, :binary.decode_unsigned(result.return_data), result.gas_used}
{:success, 42, 18}

# PUSH1 10, PUSH1 20, ADD, STOP; debug: true returns the final stack
iex> {:ok, result} = EEVM.run(<<0x60, 10, 0x60, 20, 0x01, 0x00>>, debug: true)
iex> result.stack
[30]

iex> EEVM.run(<<0xFE>>) |> elem(1) |> Map.fetch!(:status)
{:halt, :invalid_opcode}

iex> EEVM.disassemble(<<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>)
[{0, "PUSH1", "0x01"}, {2, "PUSH1", "0x02"}, {4, "ADD", nil}, {5, "STOP", nil}]
```

`:address`, `:caller`, `:value`, and `:calldata` set up the call, and `:db`,
`:block`, and `:tx` its environment. With `tracer: true`, `result.trace` holds
an opcode-level `EEVM.Tracer`, and `EEVM.Tracer.to_json/1` renders it in the
EIP-3155 format that geth and other clients use, so traces can be diffed
against them. `EEVM.transact/4` and `EEVM.Block.execute/4` take `tracer: true`
too.

### Deploy and call a contract without a key

`EEVM.create/3` deploys a contract and `EEVM.call/4` calls one by address,
like `eth_call` and revm's unsigned transactions: no signature, nonce check,
intrinsic gas, or fees, so `:caller` can be any address. `call/4` loads the
code at the address and runs it against that account's storage. Neither
commits anything: thread `result.db` into the next call, or commit it with
`EEVM.Database.commit/1`.

```elixir
# Runtime code: return storage slot 0. Initcode: store 42 in slot 0, then
# copy the runtime code from its own tail and return it.
iex> runtime = <<0x60, 0, 0x54, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xF3>>
iex> initcode = <<0x60, 42, 0x60, 0, 0x55, 0x60, 11, 0x60, 17, 0x60, 0, 0x39, 0x60, 11, 0x60, 0, 0xF3>> <> runtime
iex> {:ok, deployed} = EEVM.create(EEVM.Database.InMemory.new(), initcode, caller: 0xA11CE)
iex> {:ok, result} = EEVM.call(deployed.db, deployed.contract_address, <<>>, caller: 0xB0B)
iex> {result.status, :binary.decode_unsigned(result.return_data)}
{:success, 42}
```

`EEVM.run/2` with a `:db` needs an explicit `:address`, the account whose
balance and storage the code sees; to run a contract that is already in the
database, use `call/4`.

### Execute a transaction

`EEVM.transact/4` runs a signed transaction end to end: decode, recover the
sender, validate, charge gas, execute, refund, and pay the coinbase. It returns
`{:ok, %EEVM.TransactionResult{}}` for any transaction that passes validation,
including reverted and halted ones, and `{:error, reason}` otherwise.

```elixir
alias EEVM.{BlockEnv, Config, Database}
alias EEVM.Database.InMemory
alias EEVM.Transaction.{FeeMarket, Signer}

private_key = <<0x46::256>>
{:ok, sender} = Signer.address(private_key)
recipient = 0xB0B

db = InMemory.new(accounts: %{sender => %{balance: 10 ** 18, nonce: 0, code: <<>>}})
block = BlockEnv.new(number: 1, gas_limit: 30_000_000, base_fee: 7, coinbase: 0xC0FFEE)
config = Config.new(:cancun, chain_id: 1)

{:ok, tx} =
  %FeeMarket{max_priority_fee_per_gas: 1, max_fee_per_gas: 10, gas_limit: 21_000,
             to: recipient, value: 1_000}
  |> Signer.sign(private_key, config)

{:ok, result} = EEVM.transact(tx, block, db, config: config)

result.status
#=> :success
result.receipt
#=> %EEVM.Block.Receipt{tx_type: :eip1559, status: 1, cumulative_gas_used: 21000, ...}
Database.get_balance(result.db, recipient)
#=> 1000
EEVM.StateRoot.compute_state_root(result.db) |> Base.encode16(case: :lower)
#=> "7b838becc60c5d28adc4a332cd44cf603b4ef0e590f50a268de2457cbc78fa09"
```

A reverted transaction keeps its REVERT data in `result.return_data`, as a
reverted call does, and `EEVM.revert_reason/1` decodes Solidity's
`Error(string)` and `Panic(uint256)` payloads, or returns a custom error's
selector and arguments:

```elixir
# Revert with Panic(0x11), Solidity's arithmetic overflow: store the selector
# and the code in memory, then REVERT with those 36 bytes.
iex> code = <<0x63, 0x4E, 0x48, 0x7B, 0x71, 0x60, 224, 0x1B, 0x60, 0, 0x52,
...>   0x60, 0x11, 0x60, 4, 0x52, 0x60, 36, 0x60, 0, 0xFD>>
iex> {:ok, result} = EEVM.run(code)
iex> {result.status, EEVM.revert_reason(result)}
{:revert, {:panic, 0x11}}
```

Addresses are integers everywhere, transaction `to` included (`nil` creates a
contract), and hashes and roots are 32-byte binaries. `EEVM.address/1` and
`EEVM.hex/1` convert hex strings and binaries at the edges, and
`EEVM.bytes/1` decodes hex bytecode, calldata, or a raw transaction; the entry
points take bytes and raise (or, for a raw transaction, return
`{:error, :hex_string}`) when given a `0x` hex string. `EEVM.transact/4`
also accepts raw signed transaction bytes.
`EEVM.Transaction.Signer.address/1` turns a private key into its address, and
`EEVM.keccak256/1`, `EEVM.selector/1`, and `EEVM.event_topic/1` build calldata
and match logs:

```elixir
iex> calldata = EEVM.selector("balanceOf(address)") <> <<0xA11CE::256>>
iex> EEVM.hex(calldata)
"0x70a08231" <> String.duplicate("0", 59) <> "a11ce"
iex> EEVM.event_topic("Transfer(address,address,uint256)") == 0xDDF252AD1BE2C89B69C2B068FC378DAA952BA7F163C4A11628F55A4DF523B3EF
true
```

### Build, encode, and execute a block

`EEVM.Block` handles whole blocks. `build/4` produces a child of a parent
header: it derives the base fee and blob fields, runs the transactions, and
fills in every root. `encode/1` and `decode/1` convert to and from canonical
RLP. `execute/4` validates a block against its parent (including the EIP-7934
size limit from Osaka), applies the system calls, transactions, withdrawals,
and from Prague the EIP-7685 requests, and checks the header's commitments.
Both take the same `:config` (or `:hardfork` shorthand) option as
`EEVM.transact/4`, and errors are listed in `EEVM.Error`.

From Cancun, blocks call system contracts, and from Prague a block whose state
lacks the EIP-7002 and EIP-7251 request contracts is invalid, as on mainnet.
A chain started from scratch gets them from
`EEVM.SystemContracts.genesis_accounts/1` (or `install/2` for an existing
database):

```elixir
iex> alias EEVM.Block
iex> alias EEVM.Transaction.{FeeMarket, Signer}
iex> private_key = <<0x46::256>>
iex> {:ok, sender} = Signer.address(private_key)
iex> config = EEVM.Config.new(:prague, chain_id: 1)
iex> accounts = %{sender => %{balance: 10 ** 18}}
iex> db = EEVM.Database.InMemory.new(accounts: Map.merge(accounts, EEVM.SystemContracts.genesis_accounts(config)))
iex> tx = %FeeMarket{max_priority_fee_per_gas: 1, max_fee_per_gas: 10, gas_limit: 21_000,
...>   to: 0xB0B, value: 1_000}
iex> {:ok, tx} = Signer.sign(tx, private_key, config)
iex> parent = EEVM.Block.Header.new(gas_limit: 30_000_000, base_fee_per_gas: 7, hash: <<1::256>>)
iex> Block.build(parent, [tx], EEVM.Database.InMemory.new(accounts: accounts), config: config, timestamp: 12)
{:error, :system_contract_empty}
iex> {:ok, block, _result} = Block.build(parent, [tx], db, config: config, timestamp: 12)
iex> {:ok, decoded} = block |> Block.encode() |> Block.decode()
iex> {:ok, result} = Block.execute(decoded, parent, db, config: config)
iex> {result.gas_used, EEVM.Database.get_balance(result.db, 0xB0B)}
{21000, 1000}
```

`EEVM.Block.Processor.process_block/4` is the lower-level engine underneath; use
it directly to plug in your own transaction executor.

### State

State lives behind the read-only `EEVM.Database` behaviour: an adapter answers
`account/2`, `code/2`, `storage/3`, and `block_hash/2`, and eevm keeps every
write in its own overlay. Results carry the writes as `changes`, an
`EEVM.StateChanges`. `EEVM.transact/4` and `EEVM.Block.execute/4` commit them
when the adapter implements `commit/2`; `EEVM.run/2` never does.
`EEVM.Database.InMemory` is the built-in adapter, and the
[database adapter guide](guides/database_adapters.md) shows ETS- and RPC-backed
ones.

```elixir
iex> code = <<0x60, 5, 0x60, 0, 0x55, 0x00>>  # PUSH1 5, PUSH1 0, SSTORE, STOP
iex> {:ok, result} = EEVM.run(code, address: 0xA, db: EEVM.Database.InMemory.new())
iex> result.changes.accounts[0xA].storage
%{0 => 5}
```

## Hardforks and EIPs

Pick the rules with `config: EEVM.Config.new(fork, chain_id: id)`, or the
`:hardfork` shorthand (default `:cancun`). `EEVM.Config.hardforks/0` lists every
fork from `:frontier` to `:osaka`, and `EEVM.Config.enabled?/2` says whether an
EIP is active.

Each fork gets its own opcode set, static and dynamic gas schedule (Frontier,
EIP-150, EIP-160, EIP-1884, then EIP-2929), SSTORE metering (pre-Istanbul,
EIP-2200, EIP-2929, EIP-3529), intrinsic gas, and precompile set and prices.
Every rule is gated on the EIP that introduced it; the opcode table and precompile registry for
each fork are built at compile time.

| Area | Implemented |
|------|-------------|
| Transactions | Legacy with EIP-155, EIP-2718 envelopes, EIP-2930 access lists, EIP-1559 fee market, EIP-4844 blobs, EIP-7702 set code (partial, see [#144](https://github.com/mw2000/eevm/issues/144)), EIP-7623 calldata floor, EIP-7825 gas limit cap |
| Execution and gas | Full opcode set through Cancun (including PUSH0, TLOAD/TSTORE, MCOPY, BLOBHASH, BLOBBASEFEE), EIP-2929 warm/cold access, EIP-2200 and EIP-3529 SSTORE metering and refunds, EIP-161, EIP-170, EIP-3541, EIP-3651, EIP-3860, EIP-6780 |
| Precompiles | `0x01`–`0x11` and `0x100`: ECRECOVER, SHA256, RIPEMD160, IDENTITY, MODEXP (EIP-198, EIP-2565; EIP-7823 and EIP-7883 from Osaka), alt_bn128 (EIP-196/197), BLAKE2F (EIP-152), KZG point evaluation (EIP-4844), BLS12-381 (EIP-2537), P256VERIFY (EIP-7951, from Osaka) |
| Blocks | RLP block codec, building, header and body validation, EIP-7934 size limit, EIP-4895 withdrawals, EIP-4788 beacon roots, EIP-2935 block hashes, EIP-7685 requests (EIP-6110 deposits, EIP-7002 withdrawals, EIP-7251 consolidations), receipts, logs bloom, MPT state, transaction, and receipt roots |
| Tooling | EIP-3155 tracing, disassembler, custom precompile registration |

Osaka support (so far the CLZ opcode, EIP-7823, EIP-7825, EIP-7883, EIP-7918,
EIP-7934, and EIP-7951) is in progress. The
[roadmap](https://github.com/mw2000/eevm/issues/153) tracks what remains.

## Conformance

eevm is not yet fully conformant with the official test suites; some fixtures
still fail. Two Mix tasks run state tests and blockchain tests and print pass,
fail, and crash counts by fork and by test category. Each case runs in its own
process with a heap cap and a timeout, so a runaway case counts as a crash
instead of stopping the run. The default `mix test` run covers unit tests,
spec-derived test vectors, and small checked-in smoke fixtures, not the official
suites.

The fixtures come from two sources:

- [execution-spec-tests](https://github.com/ethereum/execution-spec-tests)
  (EEST), a pinned release fetched by `test/fixtures/eest/fetch.sh`. It is the
  authoritative suite for current forks: `fixtures_stable` covers mainnet forks
  through Prague, and the Osaka cases of `fixtures_develop`
  (`fetch.sh develop`, run with `--fork osaka`) cover Osaka.
- [`ethereum/tests`](https://github.com/ethereum/tests), a pinned submodule kept
  as the legacy suite. Its Prague BlockchainTests predate the final
  EIP-7002/EIP-7251 rule that the request contracts must have code; they are
  listed in `test/fixtures/blockchain_tests/stale_fixtures.txt`, and the runner
  reports them as `stale` rather than as failures or passes.

```bash
test/fixtures/eest/fetch.sh
mix eevm.state_tests 'test/fixtures/eest/fixtures/state_tests/**/*.json'
mix eevm.blockchain_tests 'test/fixtures/eest/fixtures/blockchain_tests/prague/**/*.json'

test/fixtures/eest/fetch.sh develop
mix eevm.blockchain_tests 'test/fixtures/eest/fixtures_develop/blockchain_tests/**/*.json' --fork osaka

git submodule update --init --depth 1 test/fixtures/state_tests/ethereum-tests
mix eevm.state_tests
mix eevm.blockchain_tests 'test/fixtures/state_tests/ethereum-tests/BlockchainTests/ValidBlocks/**/*.json'
```

CI runs every suite against its known-failures list (`test/fixtures/eest/` and
`test/fixtures/*/known_failures.txt`) and fails only when a case outside the list
fails. After fixing failures, regenerate a list with the command in its header.
`test/fixtures/*/skip.txt` lists the few fixtures that are not run at all because
they abort the VM or cannot finish within the per-case timeout.

## Examples

[`examples/devx`](https://github.com/mw2000/eevm/tree/main/examples/devx) is a Mix project that depends on eevm by
path and does seven everyday tasks with the public API only: run bytecode,
deploy and call a solc-compiled ERC-20, sign and send legacy and EIP-1559
transactions, trace, back the state with ETS, build and execute a block, and
handle reverts and invalid transactions. Its tests assert every result, and CI
runs them.

## Performance

`mix bench` runs a Benchee suite of interpreter workloads (compute loops, memory,
Keccak, storage, calls, an ERC-20 transfer) and precompiles, and prints gas/s for each.
`mix bench state_fixtures` times the slowest ethereum/tests state-test fixtures.
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
module map. The sidebar groups modules into the public API (Getting started,
Transactions, Blocks, State), extension points (Extending), and Internals, which
may change in any release. Run `mix docs` to build it locally. HexDocs will follow once the
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
