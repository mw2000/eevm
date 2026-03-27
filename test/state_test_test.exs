defmodule EEVM.StateTestTest do
  use ExUnit.Case, async: true

  alias EEVM.TestSupport.StateTestCatalog
  alias EEVM.TestSupport.StateTestFixture
  alias EEVM.TestSupport.StateTestRunner

  fixture_paths = StateTestCatalog.fixture_paths()

  for fixture_path <- fixture_paths,
      state_test <- StateTestFixture.load_file!(fixture_path),
      expectation <- StateTestFixture.expectations(state_test) do
    @tag :state_tests
    test "#{state_test.name} on #{expectation.hardfork} from #{Path.basename(fixture_path)}" do
      case StateTestCatalog.skipped?(unquote(fixture_path), unquote(state_test.name)) do
        {:ok, _reason} -> :ok
        false -> :ok
      end

      assert :ok =
               StateTestRunner.run_case(
                 unquote(Macro.escape(state_test)),
                 unquote(Macro.escape(expectation))
               )
    end
  end
end
