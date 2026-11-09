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
    test BlockchainTestCatalog.test_name(fixture_path, blockchain_test.name) do
      assert :ok = BlockchainTestRunner.run_case(unquote(Macro.escape(blockchain_test)))
    end
  end

  test "generated test names stay under ExUnit's limit and unique" do
    long_case = String.duplicate("x", 300)
    a = BlockchainTestCatalog.test_name("BlockchainTests/A/same.json", long_case)
    b = BlockchainTestCatalog.test_name("BlockchainTests/B/same.json", long_case)

    assert String.length(a) == 200
    assert a != b
    assert "short from A/same.json" == BlockchainTestCatalog.test_name("x/A/same.json", "short")
  end
end
