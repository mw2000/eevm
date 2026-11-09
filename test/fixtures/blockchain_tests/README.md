# BlockchainTest Fixtures

- `smoke/` contains tiny checked-in fixtures that exercise the harness itself;
  `mix test` runs them.
- Official `BlockchainTests` live in the `ethereum-tests` submodule under
  `test/fixtures/state_tests/ethereum-tests/BlockchainTests/` and cover
  `ValidBlocks/`, `InvalidBlocks/`, `TransitionTests/`, and
  `GeneralStateTests/` (the state tests filled as blocks).
- Transition networks such as `CancunToPragueAtTime15k` or
  `BerlinToLondonAt5` switch forks at the named block number or timestamp.
- `skip.txt` lists fixtures that are not run at all because they abort the VM
  or cannot finish within the per-case timeout.
- `known_failures.txt` lists cases that run but are known to fail. CI fails
  only when a case outside this list fails.

Initialize the upstream fixture submodule with:

```bash
git submodule update --init --depth 1 test/fixtures/state_tests/ethereum-tests
```

Run all official fixtures, or a focused subset:

```bash
mix eevm.blockchain_tests
mix eevm.blockchain_tests 'test/fixtures/state_tests/ethereum-tests/BlockchainTests/ValidBlocks/bcExample/*.json'
```

Check against the baseline as CI does, and regenerate it after fixing failures:

```bash
mix eevm.blockchain_tests --known-failures test/fixtures/blockchain_tests/known_failures.txt
mix eevm.blockchain_tests --write-known-failures test/fixtures/blockchain_tests/known_failures.txt
```
