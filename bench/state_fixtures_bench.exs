# Slow ethereum/tests GeneralStateTests fixtures: run with `mix bench state_fixtures`.
# Needs the ethereum-tests submodule (see AGENTS.md), so plain `mix bench` leaves it out.
#
# These are the fixtures test/fixtures/state_tests/skip.txt skipped, or still skips, as
# too slow for the conformance runner. A case runs for seconds to minutes, too long for
# Benchee's repeated sampling, so each fixture's heaviest Prague case (the highest gas
# limit) runs once: the transaction is timed, then its post-state root is checked.
# Several cases end in an exceptional halt by design, which burns the remaining gas at
# once, so their Mgas/s overstates throughput; compare their seconds instead.

for file <- ~w(state_test_fixture.ex tx_executor.ex) do
  Code.require_file(Path.join("../test/support", file), __DIR__)
end

alias EEVM.{Config, StateRoot}
alias EEVM.Database.InMemory
alias EEVM.TestSupport.{StateTestFixture, TxExecutor}

root = "test/fixtures/state_tests/ethereum-tests/GeneralStateTests"

# The BLAKE2F fixtures, also too slow, measure the precompile rather than the
# interpreter, so they are left out.
fixtures = ~w(
  stQuadraticComplexityTest/Call50000.json
  stQuadraticComplexityTest/Call50000_identity2.json
  stQuadraticComplexityTest/Callcode50000.json
  stQuadraticComplexityTest/QuadraticComplexitySolidity_CallDataCopy.json
  stQuadraticComplexityTest/Return50000.json
  stQuadraticComplexityTest/Return50000_2.json
  stStaticCall/static_Call1MB1024Calldepth.json
  stStaticCall/static_Call50000.json
  stStaticCall/static_Call50000_ecrec.json
  stStaticCall/static_Call50000_identity.json
  stStaticCall/static_Call50000_identity2.json
  stStaticCall/static_Call50000_rip160.json
  stStaticCall/static_Return50000_2.json
  stTimeConsuming/static_Call50000_sha256.json
  VMTests/vmPerformance/loopMul.json
)

unless File.dir?(root) do
  Mix.raise("""
  #{root} is missing. Fetch it with:

      git submodule update --init test/fixtures/state_tests/ethereum-tests
  """)
end

IO.puts("Slow state-test fixtures, heaviest Prague case, one run each (MIX_ENV=#{Mix.env()}):\n")
IO.puts(String.pad_trailing("Case", 52) <> "        gas used   seconds        Mgas/s  result")

for fixture <- fixtures, state_test <- StateTestFixture.load_file!(Path.join(root, fixture)) do
  {expectation, tx} =
    for %{hardfork: :prague} = expectation <- StateTestFixture.expectations(state_test) do
      {expectation, StateTestFixture.build_transaction(state_test, expectation)}
    end
    |> Enum.max_by(fn {_expectation, tx} -> tx.gas_limit end)

  db = InMemory.new(accounts: state_test.pre_accounts, storage: state_test.pre_storage)
  config = Config.new(expectation.hardfork)
  block = StateTestFixture.block(state_test.env, config.hardfork)

  {micros, {:ok, %{db: post_db, gas_used: gas_used}}} =
    :timer.tc(fn -> TxExecutor.execute(tx, db, block, config) end)

  result = if StateRoot.compute_state_root(post_db) == expectation.hash, do: "pass", else: "FAIL"
  %{data: d, gas: g, value: v} = expectation.indexes
  seconds = micros / 1.0e6

  IO.puts(
    String.pad_trailing("#{Path.basename(fixture, ".json")} d#{d}g#{g}v#{v}", 52) <>
      String.pad_leading(to_string(gas_used), 16) <>
      String.pad_leading(:erlang.float_to_binary(seconds, decimals: 3), 10) <>
      String.pad_leading(:erlang.float_to_binary(gas_used / seconds / 1.0e6, decimals: 1), 14) <>
      "  " <> result
  )
end
