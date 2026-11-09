# StateTest Fixtures

- `smoke/` contains tiny checked-in fixtures that exercise the harness itself;
  `mix test` runs them.
- `ethereum-tests/` is a pinned git submodule pointing at an `ethereum/tests`
  snapshot that still contains `GeneralStateTests/`.
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
mix eevm.state_tests
mix eevm.state_tests 'test/fixtures/state_tests/ethereum-tests/GeneralStateTests/stExample/*.json'
```

Check against the baseline as CI does, and regenerate it after fixing failures:

```bash
mix eevm.state_tests --known-failures test/fixtures/state_tests/known_failures.txt
mix eevm.state_tests --write-known-failures test/fixtures/state_tests/known_failures.txt
```

`--report FILE.json` writes per-fork and per-category counts plus every
failure with its reason.

Newer forks (Osaka onward) are only filled by
[execution-spec-tests](https://github.com/ethereum/execution-spec-tests/releases).
Extract `fixtures/state_tests/` from a release's `fixtures_develop.tar.gz` and
pass a glob over it to `mix eevm.state_tests`, e.g.
`.../state_tests/osaka/eip7883_modexp_gas_increase/*.json`.
