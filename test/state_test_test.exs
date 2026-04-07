defmodule EEVM.StateTestTest do
  use ExUnit.Case, async: true

  alias EEVM.TestSupport.StateTestCatalog
  alias EEVM.TestSupport.StateTestFixture
  alias EEVM.TestSupport.StateTestRunner

  fixture_paths = StateTestCatalog.fixture_paths()

  for fixture_path <- fixture_paths,
      state_test <- StateTestFixture.load_file!(fixture_path),
      expectation <- StateTestFixture.expectations(state_test),
      StateTestCatalog.skipped?(fixture_path, state_test.name) == false do
    @tag :state_tests
    test "#{state_test.name} on #{expectation.hardfork} d#{expectation.indexes.data}g#{expectation.indexes.gas}v#{expectation.indexes.value} from #{Path.basename(fixture_path)}" do
      assert :ok =
               StateTestRunner.run_case(
                 unquote(Macro.escape(state_test)),
                 unquote(Macro.escape(expectation))
               )
    end
  end
end
