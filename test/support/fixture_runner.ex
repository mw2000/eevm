defmodule EEVM.TestSupport.FixtureRunner do
  @moduledoc """
  Runs official `ethereum/tests` and execution-spec-tests fixtures at runtime and
  summarizes the results.

  The `mix eevm.state_tests` and `mix eevm.blockchain_tests` tasks build on this
  module. Fixtures are loaded one file at a time, and every case runs in its own process with a heap cap (counting
  off-heap binaries) and a wall-clock timeout. A runaway case is reported as a
  crash instead of taking the VM down.

  ## Known failures

  `--known-failures FILE` turns a run into a ratchet: the run fails only when a
  case fails that the file does not cover. A line covers a directory (`dir/`),
  a fixture file (`dir/file.json`), a test (`dir/file.json#name`), or one case
  (`dir/file.json#name@fork:d0g0v0`); lines starting with `#` are comments.
  `--write-known-failures FILE` writes the current failures in that format,
  collapsing any directory, file, or test where every case failed to one line.

  ## Fork filter

  `--fork NAME` (repeatable) runs only the cases of that fork, such as
  `--fork osaka`. A blockchain test's fork is its network's fork, or the fork
  it switches to for transition networks such as `PragueToOsakaAtTime15k`.

  ## Stale fixtures

  `--stale-fixtures FILE` lists cases, in the same format, whose fixture is
  older than a rule eevm implements, so their expectations are wrong rather
  than eevm. A listed case that fails is reported as `stale`: it counts in its
  own column, not as a failure, and never needs a known-failures entry. A
  listed case that passes is reported as a pass, with a note to drop it from
  the list.
  """

  # Fixture IDs are relative to these checkouts: ethereum/tests and the
  # execution-spec-tests release fetched by test/fixtures/eest/fetch.sh.
  @fixture_roots [
    "test/fixtures/state_tests/ethereum-tests/",
    "test/fixtures/eest/fixtures/",
    "test/fixtures/eest/fixtures_develop/"
  ]

  @suite_roots ~w(GeneralStateTests BlockchainTests state_tests blockchain_tests)

  # Directory segments that group other directories rather than name a category.
  # Lowercase fork names group EIP directories in Pyspecs and execution-spec-tests.
  @grouping_dirs ~w(BlockchainTests GeneralStateTests ValidBlocks InvalidBlocks TransitionTests
                    Pyspecs Cancun Shanghai state_tests blockchain_tests static
                    frontier homestead byzantium constantinople istanbul berlin london paris
                    shanghai cancun prague osaka)

  @switches [
    known_failures: :string,
    write_known_failures: :string,
    stale_fixtures: :string,
    report: :string,
    timeout: :integer,
    max_heap_mb: :integer,
    jobs: :integer,
    fork: :keep
  ]

  defmodule Result do
    @moduledoc false

    @type outcome :: :pass | :fail | :crash | :stale

    @type t :: %__MODULE__{
            id: String.t(),
            file: String.t(),
            category: String.t(),
            fork: atom(),
            outcome: outcome(),
            reason: term(),
            duration_ms: non_neg_integer()
          }

    defstruct [:id, :file, :category, :fork, :outcome, :reason, duration_ms: 0]
  end

  @typedoc "One runnable case: an ID suffix unique within its file, its fork, and the check to run."
  @type fixture_case :: {String.t(), atom(), (-> :ok | {:error, term()})}

  @doc """
  Entry point shared by the fixture Mix tasks; `task` names the task in the
  regenerate command written to known-failures files.

  `files_fun` receives the positional globs (or `default_glob` when none are
  given) and returns the fixture files to run; `load` turns one file into cases.
  `defaults` holds option values used when `args` doesn't set them.
  """
  @spec main(
          String.t(),
          [String.t()],
          binary(),
          ([binary()] -> [binary()]),
          (binary() -> [fixture_case()]),
          keyword()
        ) :: :ok
  def main(task, args, default_glob, files_fun, load, defaults \\ []) do
    {opts, globs} = OptionParser.parse!(args, strict: @switches)
    opts = Keyword.merge(defaults, opts)
    globs = if globs == [], do: [default_glob], else: globs
    files = files_fun.(globs)

    if files == [] do
      Mix.raise("No fixture files match #{Enum.join(globs, ", ")}. Is the submodule checked out?")
    end

    Mix.shell().info("Running #{length(files)} fixture files")
    started = System.monotonic_time(:millisecond)

    results =
      run(files, load,
        timeout: Keyword.get(opts, :timeout, 60_000),
        max_heap_bytes: Keyword.get(opts, :max_heap_mb, 1024) * 1024 * 1024,
        jobs: Keyword.get(opts, :jobs, System.schedulers_online()),
        forks: Keyword.get_values(opts, :fork)
      )
      |> mark_stale(opts[:stale_fixtures])

    # A --fork that matches nothing would otherwise pass any ratchet.
    if results == [], do: Mix.raise("No cases to run in #{length(files)} fixture files")

    elapsed = System.monotonic_time(:millisecond) - started
    print_summary(results, elapsed)

    if path = opts[:report], do: File.write!(path, report_json(results))

    if path = opts[:write_known_failures] do
      File.write!(path, [known_failures_header(task, args) | known_failure_lines(results)])
    end

    check_known_failures(results, opts[:known_failures])
  end

  @doc """
  Runs every case in `files`, loading one file at a time and running each case
  in its own process. With a non-empty `:forks` list, runs only the cases whose
  fork is named in it.
  """
  @spec run([binary()], (binary() -> [fixture_case()]), keyword()) :: [Result.t()]
  def run(files, load, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    max_heap_words = div(Keyword.fetch!(opts, :max_heap_bytes), :erlang.system_info(:wordsize))

    files
    |> Stream.flat_map(&file_cases(&1, load, Keyword.get(opts, :forks, [])))
    |> Task.async_stream(&run_case(&1, timeout, max_heap_words),
      max_concurrency: Keyword.fetch!(opts, :jobs),
      ordered: false,
      timeout: :infinity
    )
    |> Stream.with_index(1)
    |> Enum.map(fn {{:ok, result}, index} ->
      if rem(index, 5_000) == 0, do: Mix.shell().info("  #{index} cases run")
      result
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp file_cases(path, load, forks) do
    file = relative_path(path)
    template = %Result{file: file, category: category(file)}

    case load_cases(path, load) do
      {:ok, cases} ->
        for {suffix, fork, fun} <- cases, forks == [] or Atom.to_string(fork) in forks do
          {%{template | id: "#{file}##{suffix}", fork: fork}, fun}
        end

      {:error, reason} ->
        [{%{template | id: file, fork: :unknown}, {:load_failed, reason}}]
    end
  end

  defp run_case({result, {:load_failed, _} = reason}, _timeout, _max_heap_words),
    do: %{result | outcome: :crash, reason: reason}

  defp run_case({result, fun}, timeout, max_heap_words) do
    {micros, {outcome, reason}} = :timer.tc(fn -> run_isolated(fun, timeout, max_heap_words) end)
    %{result | outcome: outcome, reason: reason, duration_ms: div(micros, 1000)}
  end

  defp load_cases(path, load) do
    {:ok, load.(path)}
  rescue
    e -> {:error, Exception.message(e) |> String.slice(0, 200)}
  end

  defp run_isolated(fun, timeout, max_heap_words) do
    parent = self()
    ref = make_ref()

    max_heap = %{
      size: max_heap_words,
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    }

    {pid, monitor} =
      :erlang.spawn_opt(fn -> send(parent, {ref, apply_case(fun)}) end, [
        :monitor,
        {:max_heap_size, max_heap}
      ])

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        {:crash, :max_heap_size}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:crash, {:exit, reason}}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:crash, :timeout}
    end
  end

  defp apply_case(fun) do
    case fun.() do
      :ok -> {:pass, nil}
      {:error, reason} -> {:fail, reason}
      other -> {:fail, {:unexpected_return, other}}
    end
  rescue
    e -> {:crash, {:exception, exception_summary(e, __STACKTRACE__)}}
  catch
    kind, value -> {:crash, {kind, value}}
  end

  defp exception_summary(exception, stacktrace) do
    frame =
      case stacktrace do
        [entry | _] -> Exception.format_stacktrace_entry(entry)
        [] -> "unknown"
      end

    message =
      exception |> Exception.message() |> String.split("\n") |> hd() |> String.slice(0, 120)

    "#{inspect(exception.__struct__)} at #{frame}: #{message}"
  end

  @doc "Returns a fixture path relative to the `ethereum-tests` or EEST checkout, or to the repo."
  @spec relative_path(binary()) :: binary()
  def relative_path(path) do
    relative = path |> Path.relative_to_cwd() |> String.replace("\\", "/")
    Enum.reduce(@fixture_roots, relative, &String.replace_prefix(&2, &1, ""))
  end

  @doc """
  Groups a fixture file into a category: its directory from the suite root
  (`GeneralStateTests`, `BlockchainTests`, or an execution-spec-tests
  `state_tests`/`blockchain_tests`), cut after the first segment that names a
  test suite (`stExample`, `bcEIP1559`, `Pyspecs/cancun/eip4844_blobs`,
  `state_tests/prague/eip7702_set_code_tx`).
  """
  @spec category(binary()) :: binary()
  def category(file) do
    segments = file |> Path.dirname() |> Path.split()
    segments = Enum.drop(segments, Enum.find_index(segments, &(&1 in @suite_roots)) || 0)
    {grouping, rest} = Enum.split_while(segments, &(&1 in @grouping_dirs))
    Enum.join(grouping ++ Enum.take(rest, 1), "/")
  end

  ## Reporting

  defp print_summary(results, elapsed_ms) do
    shell = Mix.shell()
    shell.info("")
    shell.info(table("Fork", Enum.group_by(results, & &1.fork), &fork_order/1))
    shell.info("")
    shell.info(table("Category", Enum.group_by(results, & &1.category), & &1))
    shell.info("")
    shell.info(failure_groups(results))
    shell.info("")
    shell.info(slowest_passing(results))
    shell.info("")
    shell.info("#{totals_line(results)} in #{Float.round(elapsed_ms / 1000, 1)}s")
  end

  defp table(title, groups, sort_key) do
    rows =
      groups
      |> Enum.sort_by(fn {key, _} -> sort_key.(key) end)
      |> Enum.map(fn {key, results} -> Enum.map([key | counts(results)], &to_string/1) end)

    header = [title, "pass", "fail", "crash", "stale", "total", "pass%"]
    widths = column_widths([header | rows])

    [header | rows]
    |> Enum.map_join("\n", fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.with_index()
      |> Enum.map_join("  ", fn
        {{cell, width}, 0} -> String.pad_trailing(cell, width)
        {{cell, width}, _} -> String.pad_leading(cell, width)
      end)
    end)
  end

  # pass% leaves stale cases out: their fixtures, not eevm, are wrong.
  defp counts(results) do
    freq = Enum.frequencies_by(results, & &1.outcome)
    total = length(results)
    pass = Map.get(freq, :pass, 0)
    stale = Map.get(freq, :stale, 0)
    runnable = total - stale
    percent = if runnable == 0, do: 0.0, else: Float.round(pass * 100 / runnable, 1)

    [pass, Map.get(freq, :fail, 0), Map.get(freq, :crash, 0), stale, total, percent]
  end

  defp column_widths(rows) do
    rows
    |> Enum.zip_with(& &1)
    |> Enum.map(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)
  end

  defp totals_line(results) do
    [pass, fail, crash, stale, total, _] = counts(results)
    "#{total} cases: #{pass} passed, #{fail} failed, #{crash} crashed, #{stale} stale"
  end

  defp failure_groups(results) do
    groups =
      results
      |> Enum.filter(&failed?/1)
      |> Enum.frequencies_by(&reason_class/1)
      |> Enum.sort_by(fn {_, count} -> -count end)

    lines =
      Enum.map(groups, fn {class, count} -> String.pad_leading("#{count}", 7) <> "  " <> class end)

    Enum.join(["Failures by reason:" | lines], "\n")
  end

  # Passing cases near the timeout would turn into crashes on a slower machine.
  defp slowest_passing(results) do
    lines =
      results
      |> Enum.filter(&(&1.outcome == :pass))
      |> Enum.sort_by(& &1.duration_ms, :desc)
      |> Enum.take(5)
      |> Enum.map(&(String.pad_leading("#{&1.duration_ms}ms", 9) <> "  " <> &1.id))

    Enum.join(["Slowest passing cases:" | lines], "\n")
  end

  @doc "A coarse, printable failure class used to group results in the summary."
  @spec reason_class(Result.t()) :: String.t()
  def reason_class(%Result{outcome: :crash, reason: {:exception, summary}}),
    do: "crash: " <> summary

  def reason_class(%Result{outcome: :crash, reason: reason}), do: "crash: " <> short(reason)

  def reason_class(%Result{reason: {:block_failed, _number, reason}}),
    do: "block failed: " <> tag(reason)

  def reason_class(%Result{reason: reason}), do: tag(reason)

  defp tag({tag, _}) when is_atom(tag), do: inspect(tag)
  defp tag({tag, _, _}) when is_atom(tag), do: inspect(tag)
  defp tag({tag, _, _, _}) when is_atom(tag), do: inspect(tag)
  defp tag(reason), do: short(reason)

  defp short(term), do: term |> inspect(limit: 5, printable_limit: 80) |> String.slice(0, 160)

  defp report_json(results) do
    results_counts = fn group ->
      [pass, fail, crash, stale, total, _] = counts(group)
      %{pass: pass, fail: fail, crash: crash, stale: stale, total: total}
    end

    by = fn key ->
      results |> Enum.group_by(key) |> Map.new(fn {k, group} -> {k, results_counts.(group)} end)
    end

    failures =
      for result <- results, failed?(result) do
        %{
          id: result.id,
          fork: result.fork,
          outcome: result.outcome,
          class: reason_class(result),
          reason: short(result.reason)
        }
      end

    Jason.encode_to_iodata!(
      %{
        totals: results_counts.(results),
        by_fork: by.(& &1.fork),
        by_category: by.(& &1.category),
        failures: failures
      },
      pretty: true
    )
  end

  # Writes the narrowest set of entries that covers every failure: a directory,
  # file, or test where every case failed collapses to one line.
  defp known_failures_header(task, args) do
    """
    # Cases known to fail. CI fails on any failing case not covered here.
    # Each line is a directory (dir/), a fixture file, a test (file#name), or a case.
    # Regenerate after fixing failures with:
    #   mix #{task} #{Enum.map_join(args, " ", &shell_quote/1)}
    """
  end

  defp shell_quote(arg) do
    if String.match?(arg, ~r/[^\w\/.,=:@%+-]/), do: "'#{arg}'", else: arg
  end

  defp known_failure_lines(results) do
    results
    |> Enum.map(&{known_failure_keys(&1), not failed?(&1)})
    |> collapse()
    |> Enum.map(&[&1, "\n"])
  end

  defp collapse(keyed) do
    keyed
    |> Enum.reject(fn {keys, _passed?} -> keys == [] end)
    |> Enum.group_by(fn {[key | _], _} -> key end, fn {[_ | rest], passed?} -> {rest, passed?} end)
    |> Enum.sort()
    |> Enum.flat_map(fn {key, children} ->
      cond do
        Enum.all?(children, fn {_, passed?} -> passed? end) -> []
        Enum.all?(children, fn {_, passed?} -> not passed? end) -> [key]
        true -> collapse(children)
      end
    end)
  end

  defp check_known_failures(results, nil) do
    if Enum.any?(results, &failed?/1) do
      Mix.raise("Fixture failures (pass --known-failures FILE to compare against a baseline)")
    else
      :ok
    end
  end

  defp check_known_failures(results, path) do
    entries = read_entries(path)
    known? = fn %Result{} = result -> listed?(result, entries) end
    passed = Enum.filter(results, &(&1.outcome == :pass))
    regressions = results |> Enum.filter(&failed?/1) |> Enum.reject(known?)
    fixed = Enum.count(passed, known?)

    if fixed > 0 do
      Mix.shell().info(
        "#{fixed} cases covered by #{path} now pass; regenerate it with --write-known-failures"
      )
    end

    if regressions == [] do
      Mix.shell().info("No failures outside #{path}")
    else
      Enum.each(regressions, &Mix.shell().error("REGRESSION #{&1.id}: #{reason_class(&1)}"))
      Mix.raise("#{length(regressions)} cases failed that #{path} does not list")
    end
  end

  defp mark_stale(results, nil), do: results

  defp mark_stale(results, path) do
    entries = read_entries(path)

    passing =
      Enum.count(results, &(&1.outcome == :pass and listed?(&1, entries)))

    if passing > 0 do
      Mix.shell().info("#{passing} cases listed in #{path} now pass; remove them from it")
    end

    Enum.map(results, fn result ->
      if result.outcome == :fail and listed?(result, entries),
        do: %{result | outcome: :stale},
        else: result
    end)
  end

  defp failed?(%Result{outcome: outcome}), do: outcome in [:fail, :crash]

  defp listed?(%Result{} = result, entries),
    do: Enum.any?(known_failure_keys(result), &(&1 in entries))

  defp read_entries(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> MapSet.new()
  end

  # The entries that can cover a result, broadest first: each enclosing
  # directory ("dir/"), the fixture file, the test ("file#name"), and the case
  # ID ("file#name@variant"; BlockchainTest IDs have no variant).
  defp known_failure_keys(%Result{id: id, file: file}) do
    dirs =
      file
      |> Path.dirname()
      |> Path.split()
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.map(&(&1 <> "/"))

    test = id |> String.split("@") |> hd()
    Enum.uniq(dirs ++ [file, test, id])
  end

  defp fork_order(fork) do
    Enum.find_index(EEVM.HardforkConfig.all_spec_ids(), &(&1 == fork)) || 1_000
  end
end
