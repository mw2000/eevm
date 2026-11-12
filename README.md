<p align="center">
  <img src="assets/banner.png" alt="eevm logo" />
</p>

# eevm

**An Ethereum Virtual Machine written in Elixir.**

[![CI](https://github.com/mw2000/eevm/actions/workflows/ci.yml/badge.svg)](https://github.com/mw2000/eevm/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.18+-4B275F.svg)](https://elixir-lang.org)

eevm runs EVM bytecode, transactions, and blocks in pure Elixir, for every fork from Frontier to Osaka. It is its own implementation, not a wrapper around revm or evmone, and its cryptography is Elixir too, from Keccak-256 to BLS12-381 and KZG. It has no native code: no NIFs and no OTP `:crypto`.

> **Status:** eevm passes the official Ethereum test suites, apart from the exceptions under [Conformance](#conformance). It is young and its API is not yet stable, so think twice before using it where consensus correctness matters.

## Installation

eevm isn't on Hex yet. Add it from GitHub; it needs Elixir 1.18 and OTP 27 or later.

<!-- docs-check: skip -->
```elixir
def deps do
  [{:eevm, github: "mw2000/eevm"}]
end
```

## Quick start

### Run bytecode

`EEVM.run/2` runs code as a message call, without transaction rules. `status` is `:success`, `:revert`, or `{:halt, reason}`.

```elixir
# PUSH1 42, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
iex> {:ok, result} = EEVM.run(<<0x60, 42, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xF3>>)
iex> {result.status, :binary.decode_unsigned(result.return_data), result.gas_used}
{:success, 42, 18}
```

Pass `tracer: true` to get an EIP-3155 trace in `result.trace`.

### Deploy and call a contract

`EEVM.create/3` deploys a contract and `EEVM.call/4` calls it by address, with no key, nonce, or fees. `EEVM.ABI` builds the calldata and decodes the return data.

```elixir
# Runtime code: return the first argument plus 1. Initcode: copy the
# runtime code from its own tail and return it.
iex> runtime = <<0x60, 4, 0x35, 0x60, 1, 0x01, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xF3>>
iex> initcode = <<0x60, 14, 0x60, 12, 0x60, 0, 0x39, 0x60, 14, 0x60, 0, 0xF3>> <> runtime
iex> {:ok, deployed} = EEVM.create(EEVM.Database.InMemory.new(), initcode, caller: 0xA11CE)
iex> calldata = EEVM.ABI.encode_call("increment(uint256)", [41])
iex> {:ok, result} = EEVM.call(deployed.db, deployed.contract_address, calldata, caller: 0xB0B)
iex> EEVM.ABI.decode(["uint256"], result.return_data)
{:ok, [42]}
```

Neither call commits anything: pass `result.db` to the next call. `EEVM.revert_reason/1` decodes a reverted call's `Error(string)`, `Panic(uint256)`, or custom error.

### Execute a transaction

`EEVM.transact/4` runs a signed transaction end to end: validation, gas, execution, refunds, and fees. A transaction that fails validation returns `{:error, reason}`; one that reverts or halts returns `{:ok, result}` with that `status`.

```elixir
alias EEVM.{BlockEnv, Config, Database}
alias EEVM.Database.InMemory
alias EEVM.Transaction.{FeeMarket, Signer}

private_key = <<0x46::256>>
{:ok, sender} = Signer.address(private_key)
config = Config.new(:cancun, chain_id: 1)
db = InMemory.new(accounts: %{sender => %{balance: 10 ** 18, nonce: 0, code: <<>>}})
block = BlockEnv.new(number: 1, base_fee: 7, coinbase: 0xC0FFEE)

{:ok, tx} =
  %FeeMarket{max_priority_fee_per_gas: 1, max_fee_per_gas: 10, gas_limit: 21_000, to: 0xB0B, value: 1_000}
  |> Signer.sign(private_key, config)

{:ok, result} = EEVM.transact(tx, block, db, config: config)

result.receipt
#=> %EEVM.Block.Receipt{tx_type: :eip1559, status: 1, cumulative_gas_used: 21000, ...}
Database.get_balance(result.db, 0xB0B)
#=> 1000
```

The [API documentation](https://mw2000.github.io/eevm/) covers the rest: building and executing blocks with `EEVM.Block`, your own state backend with `EEVM.Database`, tracing, simulation from any address, and every error. It moves to HexDocs once eevm is on Hex.

## Hardforks and EIPs

Pick the rules with `config: EEVM.Config.new(:prague, chain_id: 1)`; the default is `:cancun`. Every rule is gated on the EIP that introduced it, and `EEVM.Config.enabled?/2` says whether an EIP is active.

| Area | Implemented |
|------|-------------|
| Transactions | Legacy with EIP-155, EIP-2718 envelopes, EIP-2930 access lists, EIP-1559 fee market, EIP-4844 blobs, EIP-7702 set code, EIP-7623 calldata floor, EIP-7825 gas limit cap, EIP-7594 blob limit |
| Execution and gas | Full opcode set through Osaka (including PUSH0, TLOAD/TSTORE, MCOPY, BLOBHASH, BLOBBASEFEE, CLZ), EIP-2929 warm/cold access, EIP-2200 and EIP-3529 SSTORE metering and refunds, EIP-161, EIP-170, EIP-3541, EIP-3651, EIP-3860, EIP-6780 |
| Precompiles | `0x01`–`0x11` and `0x100`: ECRECOVER, SHA256, RIPEMD160, IDENTITY, MODEXP (EIP-198, EIP-2565; EIP-7823 and EIP-7883 from Osaka), alt_bn128 (EIP-196/197), BLAKE2F (EIP-152), KZG point evaluation (EIP-4844), BLS12-381 (EIP-2537), P256VERIFY (EIP-7951, from Osaka) |
| Blocks | RLP block codec, building, header and body validation, EIP-7934 size limit, EIP-4895 withdrawals, EIP-4788 beacon roots, EIP-2935 block hashes, EIP-7685 requests (EIP-6110 deposits, EIP-7002 withdrawals, EIP-7251 consolidations), receipts, logs bloom, MPT state, transaction, and receipt roots |
| Tooling | EIP-3155 tracing, disassembler, custom precompile registration |

Osaka's execution-layer EIPs are implemented. The forks that only change blob parameters (EIP-7892) are not modelled.

## Conformance

CI runs both official fixture sources on every push, in the Conformance jobs of [`ci.yml`](https://github.com/mw2000/eevm/actions/workflows/ci.yml), and fails on any case that a known-failures list doesn't cover.

- [execution-spec-tests](https://github.com/ethereum/execution-spec-tests) (EEST) v5.4.0 is the authoritative suite for current forks: `fixtures_stable` through Prague, and `fixtures_develop` for Osaka.
- [`ethereum/tests`](https://github.com/ethereum/tests) at `afed83b` is the legacy suite.

| CI job | Cases passed | Known failures | Stale | Skipped fixtures | Notes |
|--------|--------------|----------------|-------|------------------|-------|
| EEST state tests | 44,039 of 44,039 | 0 | 0 | 0 | |
| EEST blockchain tests | 47,563 of 47,563 | 0 | 0 | 7 | Too slow for the CI timeout ([#224](https://github.com/mw2000/eevm/issues/224)) |
| EEST Osaka state tests | 19,517 of 19,517 | 0 | 0 | 0 | |
| EEST Osaka blockchain tests | 21,644 of 21,644 | 0 | 0 | 0 | |
| ethereum/tests state tests | 41,652 of 41,652 | 0 | 0 | 2 | Too slow for the CI timeout ([#201](https://github.com/mw2000/eevm/issues/201), [#224](https://github.com/mw2000/eevm/issues/224)) |
| ethereum/tests blockchain tests | 633 of 1,168 | 3 | 532 | 0 | Failures: the DAO fork ([#183](https://github.com/mw2000/eevm/issues/183)). Stale: Prague fixtures filled before the EIP-7002/EIP-7251 request contracts were required |

Case counts come from CI for these pinned versions, and a skipped fixture's cases aren't counted. The other columns mirror the lists in `test/fixtures/`, and a test fails when they disagree, so the table can't drift from what CI enforces. Each job's log has the latest counts.

## Contributing

Read [AGENTS.md](https://github.com/mw2000/eevm/blob/main/AGENTS.md) for the conventions and checks. Open tasks are in [GitHub Issues](https://github.com/mw2000/eevm/issues). `mix bench` benchmarks the interpreter and precompiles; [bench/README.md](bench/README.md) describes the workloads.

## License

[MIT](LICENSE)
