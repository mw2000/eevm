defmodule Mix.Tasks.Eevm.StateTests do
  @shortdoc "Runs ethereum/tests GeneralStateTests fixtures and prints a summary"

  @moduledoc """
  Runs `GeneralStateTests` fixtures from the `ethereum-tests` submodule.

      mix eevm.state_tests [GLOB...] [--known-failures FILE] [--write-known-failures FILE]
                           [--report FILE.json] [--timeout MS] [--max-heap-mb MB] [--jobs N]

  With no glob, runs every file under `GeneralStateTests/`. Files and test names
  listed in `test/fixtures/state_tests/skip.txt` are not run. Each post-state
  expectation (fork and data/gas/value index) is one case; see
  `EEVM.TestSupport.FixtureRunner` for isolation, the summary, and the
  known-failures ratchet.

  To run the pinned execution-spec-tests release instead, fetch it with
  `test/fixtures/eest/fetch.sh` and pass a glob such as
  `'test/fixtures/eest/fixtures/state_tests/**/*.json'`.
  """

  use Mix.Task

  alias EEVM.TestSupport.{FixtureRunner, StateTestCatalog, StateTestFixture, StateTestRunner}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    FixtureRunner.main(
      "eevm.state_tests",
      args,
      StateTestCatalog.official_glob(),
      &StateTestCatalog.fixture_paths/1,
      &load/1
    )
  end

  @doc "Loads the runnable cases of one fixture file; the smoke test in `mix test` reuses it."
  @spec load(Path.t()) :: [FixtureRunner.fixture_case()]
  def load(path) do
    for state_test <- StateTestFixture.load_file!(path),
        StateTestCatalog.skipped?(path, state_test.name) == false,
        expectation <- StateTestFixture.expectations(state_test) do
      %{data: d, gas: g, value: v} = expectation.indexes

      {"#{state_test.name}@#{expectation.hardfork}:d#{d}g#{g}v#{v}", expectation.hardfork,
       fn -> StateTestRunner.run_case(state_test, expectation) end}
    end
  end
end
