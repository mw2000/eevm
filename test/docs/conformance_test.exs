defmodule EEVM.Docs.ConformanceTest do
  @moduledoc """
  Keeps the README's conformance table in step with the lists CI runs
  against: each row's known failures, stale cases, and skipped fixtures must
  equal the entries of its `known_failures*.txt`, `stale_fixtures.txt`, and
  `skip.txt`, and the README must name the pinned EEST release and
  `ethereum/tests` commit. The case counts come from CI and only change with
  those pins or lists, so a stale table fails here instead of going unnoticed.
  """
  use ExUnit.Case, async: true

  @moduletag :docs

  @fixtures "test/fixtures"
  @legacy "test/fixtures/state_tests/ethereum-tests/"

  # Each CI Conformance job: its known-failures list, and the path prefixes
  # of its cases in the shared stale and skip lists.
  @jobs %{
    "EEST state tests" =>
      {"eest/known_failures_state.txt", ["test/fixtures/eest/fixtures/state_tests/"]},
    "EEST blockchain tests" =>
      {"eest/known_failures_blockchain.txt", ["test/fixtures/eest/fixtures/blockchain_tests/"]},
    "EEST Osaka state tests" =>
      {"eest/known_failures_osaka_state.txt",
       ["test/fixtures/eest/fixtures_develop/state_tests/"]},
    "EEST Osaka blockchain tests" =>
      {"eest/known_failures_osaka_blockchain.txt",
       ["test/fixtures/eest/fixtures_develop/blockchain_tests/"]},
    "ethereum/tests state tests" => {"state_tests/known_failures.txt", ["GeneralStateTests/"]},
    "ethereum/tests blockchain tests" =>
      {"blockchain_tests/known_failures.txt", ["BlockchainTests/"]}
  }

  @stale_list "blockchain_tests/stale_fixtures.txt"
  @skip_lists ["state_tests/skip.txt", "blockchain_tests/skip.txt"]

  setup_all do
    %{rows: readme_rows()}
  end

  test "the table has one row per CI Conformance job", %{rows: rows} do
    assert Enum.sort(Map.keys(rows)) == Enum.sort(Map.keys(@jobs))
  end

  test "known failures, stale cases, and skipped fixtures match the lists", %{rows: rows} do
    stale = entries(@stale_list)
    skipped = Enum.flat_map(@skip_lists, &entries/1)

    unassigned =
      Enum.reject(stale ++ skipped, fn entry -> Enum.any?(@jobs, &belongs?(entry, &1)) end)

    assert unassigned == [],
           "these stale or skip entries belong to no CI job: #{inspect(unassigned)}"

    for {job, {known_failures, _prefixes} = spec} <- @jobs do
      expected = %{
        known_failures: length(entries(known_failures)),
        stale: Enum.count(stale, &belongs?(&1, {job, spec})),
        skipped: Enum.count(skipped, &belongs?(&1, {job, spec}))
      }

      assert Map.take(rows[job], Map.keys(expected)) == expected, """
      README.md's conformance row for #{job} disagrees with test/fixtures/:
        README: #{inspect(Map.take(rows[job], Map.keys(expected)))}
        lists:  #{inspect(expected)}
      Update the row, including its case counts from the job's latest CI log.
      """
    end
  end

  test "the README names the pinned fixture versions" do
    readme = File.read!("README.md")

    [_, eest] = Regex.run(~r/^EEST_VERSION="(.+)"$/m, File.read!("test/fixtures/eest/fetch.sh"))
    assert readme =~ "(EEST) #{eest}", "README.md should name the pinned EEST release #{eest}"

    {tree, 0} = System.cmd("git", ["ls-tree", "HEAD", String.trim_trailing(@legacy, "/")])
    [_mode, "commit", sha | _] = String.split(tree)
    short = binary_part(sha, 0, 7)

    assert readme =~ "`ethereum/tests`](https://github.com/ethereum/tests) at `#{short}`",
           "README.md should name the pinned ethereum/tests commit #{short}"
  end

  # The table rows under "## Conformance", by CI job.
  defp readme_rows do
    [_, section] = String.split(File.read!("README.md"), "## Conformance\n", parts: 2)
    [section | _] = String.split(section, ~r/^## /m, parts: 2)

    for line <- String.split(section, "\n"),
        [job, _passed, failures, stale, skipped | _] <- [cells(line)],
        Map.has_key?(@jobs, job),
        into: %{} do
      {job, %{known_failures: number(failures), stale: number(stale), skipped: number(skipped)}}
    end
  end

  defp cells("|" <> row), do: row |> String.split("|") |> Enum.map(&String.trim/1)
  defp cells(_line), do: []

  defp number(cell), do: cell |> String.replace(",", "") |> String.to_integer()

  # A list's entries without comments and blank lines.
  defp entries(list) do
    for line <- File.read!(Path.join(@fixtures, list)) |> String.split("\n"),
        line = String.trim(line),
        line != "" and not String.starts_with?(line, "#"),
        do: line
  end

  # Legacy entries may be written from the submodule root or the repository root.
  defp belongs?(entry, {_job, {_known_failures, prefixes}}) do
    path = String.replace_prefix(entry, @legacy, "")
    Enum.any?(prefixes, &String.starts_with?(path, &1))
  end
end
