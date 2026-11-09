defmodule EEVM.FixtureSmokeTest do
  # Runs the checked-in smoke fixtures through the same case loaders as the
  # Conformance job's `mix eevm.state_tests` / `mix eevm.blockchain_tests`, so
  # `mix test` covers the fixture harness without the ethereum-tests submodule.
  use ExUnit.Case, async: true

  alias EEVM.TestSupport.{BlockchainTestCatalog, StateTestCatalog}

  for {suite, catalog, task} <- [
        {"state", StateTestCatalog, Mix.Tasks.Eevm.StateTests},
        {"blockchain", BlockchainTestCatalog, Mix.Tasks.Eevm.BlockchainTests}
      ] do
    test "#{suite} smoke fixtures pass" do
      cases = Enum.flat_map(unquote(catalog).fixture_paths(), &unquote(task).load/1)

      assert cases != []
      for {name, fork, run} <- cases, do: assert({name, fork, :ok} == {name, fork, run.()})
    end
  end
end
