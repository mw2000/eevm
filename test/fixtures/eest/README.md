# execution-spec-tests Fixtures

[execution-spec-tests](https://github.com/ethereum/execution-spec-tests) (EEST)
is the maintained source of Ethereum conformance fixtures and the authoritative
suite for Prague and Osaka. `fetch.sh` downloads the pinned release's
`fixtures_stable.tar.gz`, checks its SHA-256, and extracts `state_tests/` and
`blockchain_tests/` into `fixtures/` (git-ignored). `static/` in each holds the
legacy `ethereum/tests` cases refilled for current forks.

`fixtures_stable` stops at Prague. `fetch.sh develop` fetches the same
release's `fixtures_develop.tar.gz` into `fixtures_develop/`, which adds Osaka
(and the blob-parameter-only forks after it, which eevm doesn't model). Run it
with `--fork osaka` to select the Osaka cases, including
`PragueToOsakaAtTime15k` transitions.

```bash
test/fixtures/eest/fetch.sh

mix eevm.state_tests 'test/fixtures/eest/fixtures/state_tests/**/*.json'
mix eevm.blockchain_tests 'test/fixtures/eest/fixtures/blockchain_tests/prague/**/*.json'

test/fixtures/eest/fetch.sh develop
mix eevm.state_tests 'test/fixtures/eest/fixtures_develop/state_tests/**/*.json' --fork osaka
```

CI's EEST conformance jobs run each suite against its list
(`known_failures_state.txt` and `known_failures_blockchain.txt` for
`fixtures_stable`, `known_failures_osaka_state.txt` and
`known_failures_osaka_blockchain.txt` for the Osaka cases of
`fixtures_develop`) and fail on any failure the list doesn't cover.
Regenerate a list with the command in its header. Fixtures that cannot finish
within the per-case timeout are in `../state_tests/skip.txt` and
`../blockchain_tests/skip.txt`.

To move to a newer release, update `EEST_VERSION` and both SHA-256 digests in
`fetch.sh` and regenerate all four lists.
