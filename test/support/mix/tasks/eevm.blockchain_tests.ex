defmodule Mix.Tasks.Eevm.BlockchainTests do
  @shortdoc "Runs ethereum/tests BlockchainTests fixtures and prints a summary"

  @moduledoc """
  Runs `BlockchainTests` fixtures from the `ethereum-tests` submodule.

      mix eevm.blockchain_tests [GLOB...] [--known-failures FILE] [--write-known-failures FILE]
                                [--report FILE.json] [--timeout MS] [--max-heap-mb MB] [--jobs N]

  With no glob, runs every file under `BlockchainTests/`. Files and test names
  listed in `test/fixtures/blockchain_tests/skip.txt` are not run. Each test
  (one chain of blocks) is one case; see `EEVM.TestSupport.FixtureRunner` for
  isolation, the summary, and the known-failures ratchet.
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
      &load/1
    )
  end

  defp load(path) do
    for test <- BlockchainTestFixture.load_file!(path),
        BlockchainTestCatalog.skipped?(path, test.name) == false do
      {test.name, test.network, fn -> BlockchainTestRunner.run_case(test) end}
    end
  end
end
