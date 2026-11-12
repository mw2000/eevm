# Changelog

All notable changes to eevm are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and eevm follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0, a
minor version may change the public API; a deprecated function keeps working
for one minor version before it is removed.

## [Unreleased]

## [0.1.0] - 2026-11-12

The first release. eevm is an Ethereum Virtual Machine written in pure
Elixir and embedded as a library: it runs EVM bytecode, signed transactions,
and whole blocks, for every mainnet fork from Frontier to Osaka.

### Added

- **Forks.** Frontier through Osaka, chosen with
  `EEVM.Config.new(fork, chain_id: id)` (default `:cancun`). Every rule is
  gated on the EIP that introduced it, and `EEVM.Config.enabled?/2` says
  whether an EIP is active.
- **Notable EIPs.** EIP-1559 fees, EIP-2718 and EIP-2930 typed transactions,
  EIP-4844 blobs with KZG point evaluation, EIP-7702 set-code transactions,
  EIP-2929 warm and cold access, EIP-1153 transient storage, EIP-6780
  SELFDESTRUCT, EIP-2537 BLS12-381 precompiles, and from Osaka EIP-7825
  (transaction gas limit cap), EIP-7918 (blob base fee bound), EIP-7934
  (block size limit), EIP-7939 (CLZ), EIP-7951 (P256VERIFY), and EIP-7823
  and EIP-7883 (ModExp bounds and pricing). The README lists them all.
- **Running code.** `EEVM.run/2` runs bytecode as a message call.
  `EEVM.call/4` and `EEVM.create/3` call or deploy a contract from any
  address, like `eth_call`, with no key, nonce, or fees.
- **Transactions.** `EEVM.transact/4` validates and executes a signed
  transaction end to end: gas, refunds, coinbase fees, and a receipt.
  `EEVM.Transaction.Signer` signs, recovers senders, and turns a private key
  into an address; `EEVM.Transaction.Envelope` encodes and decodes the wire
  format.
- **Blocks.** `EEVM.Block.build/4`, `validate/3`, and `execute/4` build,
  check, and apply blocks, including withdrawals, the EIP-4788 and EIP-2935
  system calls, EIP-7685 requests, receipts, logs bloom, and the state,
  transaction, and receipt roots. `EEVM.Block.encode/1` and `decode/1` are
  the RLP codec, and `EEVM.SystemContracts.genesis_accounts/1` sets up a new
  chain.
- **ABI and errors.** `EEVM.ABI` encodes calls and decodes return data and
  logs. `EEVM.revert_reason/1` decodes `Error(string)`, `Panic(uint256)`, and
  custom errors. Every error reason is listed, with a message, in
  `EEVM.Error`; `details: true` on `EEVM.transact/4` returns the values a
  failed check compared.
- **State.** The read-only `EEVM.Database` behaviour plugs in your own state
  backend, such as ETS or a node's JSON-RPC; `use EEVM.Database` makes a
  read-only adapter just four read callbacks. eevm keeps every write in an
  immutable overlay and returns it as `EEVM.StateChanges`.
  `EEVM.Database.InMemory` is built in.
- **Tracing.** `tracer: true` on any entry point records an EIP-3155 trace;
  `EEVM.Tracer.steps/1` and `EEVM.Tracer.to_json/1` read it.
- **Simulation mode.** `EEVM.transact/4` takes an unsigned `EEVM.TxEnv` to
  run a transaction from any address, and `EEVM.Config`'s `disable_*`
  switches relax the nonce, balance, base-fee, block-gas-limit, and EIP-3607
  checks for tooling.
- **Custom precompiles** through `EEVM.Precompile` and
  `EEVM.Config.register_precompile/3`.
- **Conformance.** CI runs the official execution-spec-tests (v5.4.0,
  through Osaka) and `ethereum/tests` suites on every push. The
  [Conformance table](README.md#conformance) has the counts and the
  exceptions.
- **No native code.** All cryptography is Elixir, from Keccak-256,
  secp256k1, and P-256 to BN254, BLS12-381, and KZG: no NIFs, no Rust, and no
  OTP `:crypto`.

### Known limitations

- The DAO fork's irregular state change (EIP-779) isn't implemented, so 3
  legacy blockchain fixtures fail
  ([#183](https://github.com/mw2000/eevm/issues/183)).
- 9 stress-test fixtures are skipped in CI because they run past its
  timeout: 50,000 STATICCALLs (to SHA-256 and other precompiles), a 1 MB
  call at depth 1,024, and BLAKE2F at maximum rounds
  ([#201](https://github.com/mw2000/eevm/issues/201),
  [#224](https://github.com/mw2000/eevm/issues/224)).
- eevm is young and not proven in production. Think twice before relying on
  it where consensus correctness matters. The simulation switches are never
  for consensus, and `EEVM.Block` refuses a config that sets one.
- The API is pre-1.0 and may change in a minor version. Some names from
  before this release remain as deprecated delegates, whose compiler
  warnings name the replacement.

[Unreleased]: https://github.com/mw2000/eevm/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mw2000/eevm/releases/tag/v0.1.0
