defmodule EEVM.Docs.SnippetsTest do
  @moduledoc """
  Runs the code a user copies out of the docs.

  - Every `iex>` example in the guides and in the public modules' docs runs
    as a doctest. (The README's run from `test/eevm_test.exs`.)
  - Every other ```` ```elixir ```` block in the README and guides runs, in
    order, in one environment per file, so later blocks can use the
    variables, aliases, and modules of earlier ones. A `#=> value` line
    after an expression asserts that the expression's value matches
    `value` as a pattern, with `...` standing for the omitted fields.
    Compiler warnings fail the block.

  Put `<!-- docs-check: skip -->` on the line before a block that isn't
  meant to run on its own, such as a `mix.exs` excerpt.
  """
  use ExUnit.Case, async: true

  @moduletag :docs

  @public_groups [:"Getting started", :Transactions, :Blocks, :State, :Extending]
  @skip_marker "<!-- docs-check: skip -->"

  docs = Mix.Project.config()[:docs]

  pages =
    for extra <- docs[:extras],
        path = if(is_tuple(extra), do: elem(extra, 0), else: extra),
        String.ends_with?(path, ".md"),
        path != "bench/README.md",
        do: path

  for page <- pages, page != "README.md" do
    doctest_file(page)
  end

  {:ok, modules} = :application.get_key(:eevm, :modules)

  # Each module's docs group: the first group that matches it, as in ExDoc.
  public_modules =
    for module <- modules,
        {group, _} =
          Enum.find(docs[:groups_for_modules], {nil, nil}, fn {_, matchers} ->
            Enum.any?(matchers, fn
              %Regex{} = regex -> Regex.match?(regex, inspect(module))
              matcher -> matcher == module
            end)
          end),
        group in @public_groups,
        do: module

  for module <- Enum.sort(public_modules) do
    doctest module
  end

  for page <- pages do
    @page page
    test "the elixir blocks in #{page} run and match their #=> results" do
      env = Code.env_for_eval(file: Path.expand(@page))

      @page
      |> File.read!()
      |> code_blocks()
      |> Enum.reduce({[], env}, fn {line, code}, {binding, env} ->
        run_block(code, line, binding, env)
      end)
    end
  end

  # {line, code} for each elixir block that isn't an iex session or skipped.
  defp code_blocks(markdown) do
    lines = String.split(markdown, "\n")

    ~r/^```elixir\n(.*?)^```/ms
    |> Regex.scan(markdown, return: :index, capture: :all)
    |> Enum.map(fn [{start, _}, {code_start, code_length}] ->
      line = markdown |> binary_part(0, start) |> String.split("\n") |> length()
      previous = if line > 1, do: Enum.at(lines, line - 2), else: ""
      {line, previous, binary_part(markdown, code_start, code_length)}
    end)
    |> Enum.reject(fn {_, previous, code} ->
      String.trim(previous) == @skip_marker or code =~ "iex>"
    end)
    |> Enum.map(fn {line, _, code} -> {line + 1, code} end)
  end

  # Runs a block chunk by chunk: each chunk ends at a `#=>` line, whose
  # pattern the chunk's value must match.
  defp run_block(code, first_line, binding, env) do
    code
    |> String.split("\n")
    |> Enum.with_index(first_line)
    |> Enum.chunk_while(
      [],
      fn {text, line}, acc ->
        case Regex.run(~r/^\s*#=>\s*(.*)$/, text) do
          [_, expected] -> {:cont, {Enum.reverse(acc), {expected, line}}, []}
          nil -> {:cont, [{text, line} | acc]}
        end
      end,
      fn acc -> {:cont, {Enum.reverse(acc), nil}, []} end
    )
    |> Enum.reduce({binding, env}, fn {chunk, expected}, {binding, env} ->
      run_chunk(chunk, expected, binding, env)
    end)
  end

  defp run_chunk([], nil, binding, env), do: {binding, env}

  defp run_chunk(chunk, expected, binding, env) do
    [{_, line} | _] = chunk
    source = Enum.map_join(chunk, "\n", &elem(&1, 0))

    {{value, binding, env}, diagnostics} =
      Code.with_diagnostics(fn ->
        quoted = Code.string_to_quoted!(source, file: env.file, line: line)
        Code.eval_quoted_with_env(quoted, binding, env)
      end)

    warnings =
      for %{severity: :warning} = d <- diagnostics,
          do: "  line #{inspect(d.position)}: #{d.message}"

    assert warnings == [],
           "#{env.file}:#{line}: the block compiles with warnings:\n#{Enum.join(warnings, "\n")}"

    with {pattern, expected_line} <- expected do
      pattern_source = String.replace(pattern, ~r/,?\s*\.\.\./, "")

      check =
        Code.string_to_quoted!("match?(#{pattern_source}, value)",
          file: env.file,
          line: expected_line
        )

      {matched?, _, _} = Code.eval_quoted_with_env(check, [value: value], env)

      assert matched?, """
      #{env.file}:#{expected_line}: expected the value to match
        #{pattern}
      got
        #{inspect(value, pretty: true, limit: 20)}
      """
    end

    {binding, env}
  end
end
