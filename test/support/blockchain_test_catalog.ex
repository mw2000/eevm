defmodule EEVM.TestSupport.BlockchainTestCatalog do
  @moduledoc "Discovers BlockchainTest JSON fixtures on disk and filters them against the skip list."

  @default_glob "test/fixtures/blockchain_tests/smoke/*.json"
  @official_glob "test/fixtures/state_tests/ethereum-tests/BlockchainTests/**/*.json"
  @default_skip_file "test/fixtures/blockchain_tests/skip.txt"

  @spec fixture_paths() :: [binary()]
  def fixture_paths do
    skip_entries = skip_entries()

    fixture_globs()
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reject(&skip_file_path?(&1, skip_entries))
  end

  # ExUnit rejects test names of 255 characters or more (they become atoms)
  # and duplicate names. EEST-generated case names in BlockchainTests reach ~390
  # characters, so long labels are truncated and suffixed with a hash of the
  # full label. The fixture's parent directory is part of the label because
  # the same file name and case name recur across directories.
  @max_test_name_length 200
  @hash_suffix_length 8

  @doc "Returns the ExUnit test name for a fixture case, at most 200 characters long."
  @spec test_name(binary(), binary()) :: binary()
  def test_name(fixture_path, test_name) do
    file =
      Path.join(fixture_path |> Path.dirname() |> Path.basename(), Path.basename(fixture_path))

    label = "#{test_name} from #{file}"

    if String.length(label) <= @max_test_name_length do
      label
    else
      hash =
        :crypto.hash(:sha256, label)
        |> Base.encode16(case: :lower)
        |> binary_part(0, @hash_suffix_length)

      String.slice(label, 0, @max_test_name_length - @hash_suffix_length - 2) <> " #" <> hash
    end
  end

  @spec skipped?(binary(), binary()) :: {:ok, binary()} | false
  def skipped?(fixture_path, test_name) do
    relative_path = repo_relative(fixture_path)

    Enum.find_value(skip_entries(), false, fn entry ->
      cond do
        entry == relative_path -> {:ok, "skipped by fixture path"}
        entry == "#{relative_path}##{test_name}" -> {:ok, "skipped by fixture test name"}
        entry == test_name -> {:ok, "skipped by test name"}
        true -> false
      end
    end)
  end

  defp fixture_globs do
    case System.get_env("EEVM_BLOCKCHAIN_TEST_GLOB") do
      nil ->
        [@default_glob]

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
    end
  end

  @spec official_glob() :: binary()
  def official_glob, do: @official_glob

  defp skip_entries do
    skip_file = System.get_env("EEVM_BLOCKCHAIN_TEST_SKIP_FILE", @default_skip_file)

    if File.exists?(skip_file) do
      skip_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    else
      []
    end
  end

  defp skip_file_path?(path, entries) do
    relative_path = repo_relative(path)
    Enum.member?(entries, relative_path)
  end

  defp repo_relative(path) do
    path
    |> Path.relative_to_cwd()
    |> String.replace("\\", "/")
  end
end
