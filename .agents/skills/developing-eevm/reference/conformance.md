# Conformance suites

`mix eevm.state_tests` and `mix eevm.blockchain_tests` run official fixtures; `mix test` does not. `.agents/setup` fetches all of them. By hand:

```bash
test/fixtures/eest/fetch.sh            # EEST fixtures_stable (through Prague) -> test/fixtures/eest/fixtures/
test/fixtures/eest/fetch.sh develop    # EEST fixtures_develop (adds Osaka)   -> test/fixtures/eest/fixtures_develop/
git submodule update --init --depth 1 test/fixtures/state_tests/ethereum-tests   # legacy ethereum/tests
```

EEST is authoritative for current forks. Prague BlockchainTests in the pinned `ethereum/tests` snapshot predate EIP-7002 and EIP-7251 and fail with `:system_contract_empty`; `stale_fixtures.txt` covers the ones the CI glob runs.

## While iterating

Run the directory your change touches. Add `--fork NAME` to run only that fork's cases, which every Osaka run of `fixtures_develop` needs. Pass the list CI uses with `--known-failures` so the run fails only on new failures.

```bash
mix eevm.state_tests 'test/fixtures/eest/fixtures_develop/state_tests/osaka/eip7939_count_leading_zeros/**/*.json' \
  --fork osaka --known-failures test/fixtures/eest/known_failures_osaka_state.txt
mix eevm.blockchain_tests 'test/fixtures/state_tests/ethereum-tests/BlockchainTests/ValidBlocks/bcExample/*.json' \
  --known-failures test/fixtures/blockchain_tests/known_failures.txt
```

Quote globs so the task expands `**`, not the shell.

## Reading the output

- Per-fork and per-category tables count `pass`, `fail`, `crash` (timeout, heap cap, or exception), and `stale`. `pass%` leaves stale cases out.
- `Failures by reason` groups failures; `Slowest passing cases` shows what nears the timeout.
- With `--known-failures`, each failure the list does not cover prints as `REGRESSION <case id>: <reason>` and the task exits non-zero. A case that the list covers and now passes prints `N cases covered by FILE now pass; regenerate it with --write-known-failures`.
- A case ID is `<path below the fixture root>#<test name>@<fork>:d<data>g<gas>v<value>`; blockchain cases have no `@...` suffix. Rerun one test by passing its file as the glob.
- `--report FILE.json` writes `totals`, `by_fork`, `by_category`, and `failures` (each with `id`, `fork`, `outcome`, `reason`). For example `jq '.failures | group_by(.reason) | map([.[0].reason, length])' FILE.json`.
- The default timeout is 60 s per case and `--jobs` defaults to the number of schedulers. CI passes `--timeout 180000` (300000 for EEST blockchain tests), so pass the same when you compare against a list.

## The six CI ratchets

Each list's header holds the exact command that regenerates it. All six take about 12 minutes on an orb.

- `test/fixtures/state_tests/known_failures.txt`: ethereum/tests GeneralStateTests.
- `test/fixtures/blockchain_tests/known_failures.txt`: ethereum/tests BlockchainTests (ValidBlocks, InvalidBlocks, TransitionTests).
- `test/fixtures/eest/known_failures_state.txt` and `known_failures_blockchain.txt`: EEST `fixtures_stable`.
- `test/fixtures/eest/known_failures_osaka_state.txt` and `known_failures_osaka_blockchain.txt`: the Osaka cases of EEST `fixtures_develop`.

To check a list without changing it, run its header command with `--known-failures FILE` in place of `--write-known-failures FILE`.

## Changing the lists

- `known_failures*.txt`: after a fix, run the header command of every list the fix can affect and commit the lists with the fix. `--write-known-failures` writes only the failures of the run you made, collapses a directory, file, or test where every case failed to one line, and copies your command into the header. So always run the header command unchanged; a narrower glob or a missing `--fork` deletes the other entries. Never add entries for a regression your change caused; fix it.
- `skip.txt` (one per legacy suite; EEST runs read them too): fixtures that are never run, only because they crash the VM or cannot finish within the per-case timeout. Lines are a fixture path, `path#test_name`, or a bare test name. Put a comment above each entry with the reason and the issue that re-enables it. Time a candidate alone with `mix eevm.state_tests <file> --jobs 1 --timeout 600000`, and re-enable an entry once it takes under half of CI's timeout. `mix bench state_fixtures` times the skipped slow fixtures.
- `test/fixtures/blockchain_tests/stale_fixtures.txt`: cases whose fixture predates a rule eevm implements, so the fixture is wrong. `mix eevm.blockchain_tests` reads it by default and reports listed failures as `stale`. List whole tests (`file#name`), never files or directories. When the run prints `N cases listed in FILE now pass; remove them from it`, delete those lines. Add a case only with the rule and the upstream refill that proves the fixture stale, as the header does.
- Moving to a newer EEST release: update `EEST_VERSION` and both SHA-256 digests in `test/fixtures/eest/fetch.sh`, rerun both fetches, and regenerate all four EEST lists.
