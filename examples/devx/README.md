# eevm developer-experience examples

A Mix project that uses eevm the way a library user would: it depends on eevm
by path and calls only the public API. Each module in `lib/devx/` does one
everyday task, and `test/` asserts what it returns, with expected values
taken from the Yellow Paper, the EIPs, and the Solidity docs rather than from
eevm.

| Task | Module |
|------|--------|
| 1. Run bytecode and read the result, gas, and return data | `Devx.RunBytecode` |
| 2. Deploy a solc-compiled ERC-20, then call `transfer` and `balanceOf` | `Devx.Erc20` |
| 3. Sign and execute legacy and EIP-1559 transactions | `Devx.Transactions` |
| 4. Trace an execution opcode by opcode | `Devx.Tracing` |
| 5. Write a custom `EEVM.Database` backend | `Devx.EtsDatabase`, and the read-only `Devx.ReadOnlyDatabase` |
| 6. Build, encode, validate, and execute a block | `Devx.Blocks` |
| 7. Handle reverts, out-of-gas halts, and invalid transactions | `Devx.Errors` |

`test/public_api_test.exs` reads the calls compiled into these modules and
fails when one calls an eevm function that is in the Internals docs group,
hidden, or deprecated. Tests tagged `skip` name the open issue they wait on.

```bash
cd examples/devx
mix deps.get
mix test
```

`priv/Token.bin` is `priv/Token.sol` compiled with solc 0.8.28:

```bash
npx solc@0.8.28 --bin --optimize --optimize-runs 200 -o out priv/Token.sol
```
