defmodule EEVM.BlockchainTestTest do
  use ExUnit.Case, async: true

  alias EEVM.TestSupport.{
    BlockchainTestCatalog,
    BlockchainTestFixture,
    BlockchainTestRunner
  }

  fixture_paths = BlockchainTestCatalog.fixture_paths()

  for fixture_path <- fixture_paths,
      blockchain_test <- BlockchainTestFixture.load_file!(fixture_path),
      BlockchainTestCatalog.skipped?(fixture_path, blockchain_test.name) == false do
    @tag :blockchain_tests
    test "#{blockchain_test.name} from #{Path.basename(fixture_path)}" do
      assert :ok = BlockchainTestRunner.run_case(unquote(Macro.escape(blockchain_test)))
    end
  end
end
