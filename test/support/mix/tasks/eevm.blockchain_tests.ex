defmodule Mix.Tasks.Eevm.BlockchainTests do
  @shortdoc "Runs ethereum/tests BlockchainTests fixtures and prints a summary"

  @moduledoc """
  Runs `BlockchainTests` fixtures from the `ethereum-tests` submodule.

      mix eevm.blockchain_tests [GLOB...] [--known-failures FILE] [--write-known-failures FILE]
                                [--stale-fixtures FILE] [--report FILE.json] [--timeout MS]
                                [--max-heap-mb MB] [--jobs N] [--fork NAME]

  With no glob, runs every file under `BlockchainTests/`. Files and test names
  listed in `test/fixtures/blockchain_tests/skip.txt` are not run. Each test
  (one chain of blocks) is one case; see `EEVM.TestSupport.FixtureRunner` for
  isolation, the summary, and the known-failures ratchet.

  To run the pinned execution-spec-tests release instead, fetch it with
  `test/fixtures/eest/fetch.sh` and pass a glob such as
  `'test/fixtures/eest/fixtures/blockchain_tests/**/*.json'`.

  `--stale-fixtures` defaults to `test/fixtures/blockchain_tests/stale_fixtures.txt`:
  cases of the pinned snapshot filled before a rule eevm implements, reported
  as `stale` instead of failing.
  """

  use Mix.Task

  alias EEVM.TestSupport.{
    BlockchainTestCatalog,
    BlockchainTestFixture,
    BlockchainTestRunner,
    FixtureRunner
  }

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    FixtureRunner.main(
      "eevm.blockchain_tests",
      args,
      BlockchainTestCatalog.official_glob(),
      &BlockchainTestCatalog.fixture_paths/1,
      &load/1,
      stale_fixtures: "test/fixtures/blockchain_tests/stale_fixtures.txt"
    )
  end

  @doc "Loads the runnable cases of one fixture file; the smoke test in `mix test` reuses it."
  @spec load(Path.t()) :: [FixtureRunner.fixture_case()]
  def load(path) do
    for test <- BlockchainTestFixture.load_file!(path),
        BlockchainTestCatalog.skipped?(path, test.name) == false do
      {test.name, fork(test.network), fn -> BlockchainTestRunner.run_case(test) end}
    end
  end

  defp fork({:unsupported, _name}), do: :unsupported
  defp fork(fork), do: fork
end
