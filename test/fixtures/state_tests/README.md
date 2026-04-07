# StateTest Fixtures

- `smoke/` contains tiny checked-in fixtures that exercise the harness itself.
- `ethereum-tests/` is a pinned git submodule pointing at an `ethereum/tests` snapshot that still contains `GeneralStateTests/`.
- `skip.txt` lists fixtures or test names to skip while the runner support grows.

Initialize the upstream fixture submodule with:

```bash
git submodule update --init test/fixtures/state_tests/ethereum-tests
```

Run a focused official subset with:

```bash
EEVM_STATE_TEST_GLOB='test/fixtures/state_tests/ethereum-tests/GeneralStateTests/stExample/*.json' \
  mix test test/state_test_test.exs
```
