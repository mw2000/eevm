defmodule Mix.Tasks.FetchStateTests do
  use Mix.Task

  @shortdoc "Download and extract official ethereum/tests GeneralStateTests fixtures"

  @default_url "https://raw.githubusercontent.com/ethereum/tests/develop/fixtures_general_state_tests.tgz"
  @default_dest "test/fixtures/state_tests/official"
  @default_strip_components 1

  @switches [
    url: :string,
    dest: :string,
    clean: :boolean,
    dry_run: :boolean,
    strip_components: :integer
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)

    options = %{
      url: Keyword.get(opts, :url, @default_url),
      dest: Keyword.get(opts, :dest, @default_dest),
      clean?: Keyword.get(opts, :clean, false),
      dry_run?: Keyword.get(opts, :dry_run, false),
      strip_components: Keyword.get(opts, :strip_components, @default_strip_components)
    }

    validate_options!(options)

    repo_root = File.cwd!()
    destination = Path.expand(options.dest, repo_root)

    Mix.shell().info("Downloading #{options.url}")

    with {:ok, _started} <- ensure_http_clients_started(),
         {:ok, archive} <- download_archive(options.url),
         {:ok, temp_dir} <- make_temp_dir(),
         :ok <- write_archive(temp_dir, archive),
         :ok <- maybe_clean_destination(destination, options),
         :ok <- maybe_extract_archive(temp_dir, destination, options) do
      Mix.shell().info("Fixtures ready in #{destination}")
    else
      {:error, reason} -> Mix.raise("failed to fetch StateTests: #{format_error(reason)}")
    end
  end

  defp ensure_http_clients_started do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      {:ok, :started}
    end
  end

  defp download_archive(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_version, 200, _reason_phrase}, _headers, body}} -> {:ok, body}
      {:ok, {{_version, status, reason_phrase}, _headers, _body}} -> {:error, {status, reason_phrase}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp make_temp_dir do
    temp_dir = Path.join(System.tmp_dir!(), "eevm_state_tests_#{System.unique_integer([:positive])}")

    case File.mkdir_p(temp_dir) do
      :ok -> {:ok, temp_dir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_archive(temp_dir, archive) do
    archive_path = archive_path(temp_dir)
    File.write(archive_path, archive)
  end

  defp maybe_clean_destination(destination, %{clean?: true, dry_run?: dry_run?}) do
    if File.exists?(destination) do
      Mix.shell().info("Removing #{destination}")

      if dry_run? do
        :ok
      else
        File.rm_rf!(destination)
        :ok
      end
    else
      :ok
    end
  end

  defp maybe_clean_destination(_destination, _options), do: :ok

  defp maybe_extract_archive(temp_dir, _destination, %{dry_run?: true} = options) do
    extracted_dir = Path.join(temp_dir, "extracted")

    with :ok <- File.mkdir_p(extracted_dir),
         :ok <- extract_archive(archive_path(temp_dir), extracted_dir),
         selected_files <- selected_files(extracted_dir, options.strip_components) do
      Enum.each(selected_files, fn {_source, relative_path} ->
        Mix.shell().info("Extracting #{relative_path}")
      end)

      :ok
    end
  end

  defp maybe_extract_archive(temp_dir, destination, options) do
    extracted_dir = Path.join(temp_dir, "extracted")

    with :ok <- File.mkdir_p(extracted_dir),
         :ok <- extract_archive(archive_path(temp_dir), extracted_dir),
         :ok <- File.mkdir_p(destination),
         :ok <- copy_extracted_files(extracted_dir, destination, options) do
      :ok
    end
  end

  defp extract_archive(archive_path, destination) do
    case :erl_tar.extract(String.to_charlist(archive_path), [:compressed, cwd: String.to_charlist(destination)]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_extracted_files(extracted_dir, destination, options) do
    extracted_dir
    |> selected_files(options.strip_components)
    |> Enum.reduce_while(:ok, fn {source, relative_path}, :ok ->
      Mix.shell().info("Extracting #{relative_path}")

      target = Path.join(destination, relative_path)

      case copy_file(source, target) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_file(source, target) do
    with :ok <- File.mkdir_p(Path.dirname(target)),
         {:ok, _bytes} <- File.copy(source, target) do
      :ok
    end
  end

  defp selected_files(root_dir, strip_components) do
    root_dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn absolute_path ->
      relative_source_path = Path.relative_to(absolute_path, root_dir)

      case strip_path(relative_source_path, strip_components) do
        nil -> nil
        relative_target_path -> {absolute_path, relative_target_path}
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_source, relative_target_path} -> relative_target_path end)
  end

  defp strip_path(path, strip_components) do
    parts = Path.split(path)

    if length(parts) <= strip_components do
      nil
    else
      parts
      |> Enum.drop(strip_components)
      |> Path.join()
    end
  end

  defp archive_path(temp_dir), do: Path.join(temp_dir, "fixtures_general_state_tests.tgz")

  defp validate_options!(%{strip_components: value}) when is_integer(value) and value >= 0, do: :ok
  defp validate_options!(_options), do: Mix.raise("--strip-components must be a non-negative integer")

  defp format_error({status, reason_phrase}), do: "HTTP #{status} #{List.to_string(reason_phrase)}"
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
