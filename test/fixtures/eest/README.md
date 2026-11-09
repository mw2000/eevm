# execution-spec-tests Fixtures

[execution-spec-tests](https://github.com/ethereum/execution-spec-tests) (EEST)
is the maintained source of Ethereum conformance fixtures and the authoritative
suite for Prague and Osaka. `fetch.sh` downloads the pinned release's
`fixtures_stable.tar.gz`, checks its SHA-256, and extracts `state_tests/` and
`blockchain_tests/` into `fixtures/` (git-ignored). `static/` in each holds the
legacy `ethereum/tests` cases refilled for current forks.

```bash
test/fixtures/eest/fetch.sh

mix eevm.state_tests 'test/fixtures/eest/fixtures/state_tests/**/*.json'
mix eevm.blockchain_tests 'test/fixtures/eest/fixtures/blockchain_tests/prague/**/*.json'
```

CI's EEST conformance job runs both suites against `known_failures_state.txt`
and `known_failures_blockchain.txt` and fails on any failure they don't cover.
Regenerate a list with the command in its header. Fixtures that cannot finish
within the per-case timeout are in `../state_tests/skip.txt` and
`../blockchain_tests/skip.txt`.

To move to a newer release, update `EEST_VERSION` and `EEST_SHA256` in
`fetch.sh` and regenerate both lists.
