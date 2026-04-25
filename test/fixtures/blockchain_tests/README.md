# BlockchainTest Fixtures

- `smoke/` is a place for tiny checked-in fixtures that exercise the harness
  itself.
- Official `BlockchainTests` live in the `ethereum-tests` submodule under
  `test/fixtures/state_tests/ethereum-tests/BlockchainTests/`.
- `skip.txt` lists fixtures or test names to skip.

Initialize the upstream fixture submodule with:

```bash
git submodule update --init test/fixtures/state_tests/ethereum-tests
```

Run a focused official subset:

```bash
EEVM_BLOCKCHAIN_TEST_GLOB='test/fixtures/state_tests/ethereum-tests/BlockchainTests/ValidBlocks/bcExample/*.json' \
  mix test test/blockchain_test_test.exs
```
