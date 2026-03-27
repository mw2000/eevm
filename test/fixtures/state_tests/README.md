# StateTest Fixtures

- `smoke/` contains tiny checked-in fixtures that exercise the harness itself.
- `official/` is where imported `ethereum/tests` GeneralStateTests fixtures live.
- `skip.txt` lists fixtures or test names to skip while the runner support grows.

Fetch the official GeneralStateTests bundle with:

```bash
python3 scripts/fetch_state_tests.py --clean
```

That downloads `fixtures_general_state_tests.tgz` from `ethereum/tests` and extracts it into `test/fixtures/state_tests/official/`.
