defmodule EEVM.Docs.SurfaceTest do
  @moduledoc """
  Lints the public docs surface: the pages in the public docs groups of
  `mix.exs` (Getting started, Transactions, Blocks, State, Extending) and the
  user-facing ExDoc extras (the README) must never tell a user to call an
  internal or deprecated function or to use a deprecated module, and every
  public struct must document its fields.

  Naming an Internals module is fine (the README's architecture overview and
  `EEVM.Error`'s source columns do); calling one of its functions is not. A
  reference inside a passage about a deprecation (a section whose heading,
  or a paragraph whose text, says "deprecated") is allowed: that is where a
  deprecated name belongs.
  """
  use ExUnit.Case, async: true

  @moduletag :docs

  @public_groups [:"Getting started", :Transactions, :Blocks, :State, :Extending]

  # Extras written for contributors, not library users.
  @contributor_extras ["bench/README.md"]

  # Known violations, each with the issue that removes it. Like the purity
  # test's allow-list, it only shrinks: the test fails on an entry nothing
  # needs, so delete an entry once its issue lands.
  @pending %{}

  # Structs whose fields are an implementation detail: callers use the
  # module's functions, never the fields.
  @opaque_structs %{
    EEVM.Database => "an overlay read and written through EEVM.Database functions",
    EEVM.Tracer => "read through EEVM.Tracer.steps/1"
  }

  setup_all do
    groups = module_groups()
    {:ok, groups: groups, modules: Map.keys(groups)}
  end

  test "public pages and extras reference only public, non-deprecated API", ctx do
    found =
      for {page, current, text} <- public_texts(ctx.groups),
          ref <- references(text, current, ctx.modules),
          problem = problem(ref, ctx.groups),
          do: {page, ref, problem}

    pending_hits = MapSet.new(found, fn {page, ref, _} -> {page, ref_module(ref)} end)

    violations =
      Enum.reject(found, fn {page, ref, _} -> Map.has_key?(@pending, {page, ref_module(ref)}) end)

    assert violations == [], """
    Public docs reference API a user shouldn't call:

    #{Enum.map_join(Enum.uniq(violations), "\n", fn {page, ref, problem} -> "  #{page}: #{format_ref(ref)} (#{problem})" end)}

    Point the text at the public API instead, or move it into a passage about the deprecation.
    """

    stale = @pending |> Map.keys() |> Enum.reject(&MapSet.member?(pending_hits, &1))
    assert stale == [], "Remove these @pending entries, nothing needs them now: #{inspect(stale)}"
  end

  test "public structs document every field", ctx do
    missing =
      for {module, group} <- ctx.groups,
          group in @public_groups,
          not Map.has_key?(@opaque_structs, module),
          Code.ensure_loaded!(module) && function_exported?(module, :__struct__, 0),
          {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} <- [Code.fetch_docs(module)],
          field <- Map.keys(module.__struct__()) -- [:__struct__, :__exception__],
          not String.contains?(moduledoc, "`#{field}`"),
          do: "#{inspect(module)}.#{field}"

    assert missing == [], """
    These public struct fields are not documented in their module's @moduledoc
    (as `field`, usually in a field table):

      #{Enum.join(Enum.sort(missing), "\n  ")}
    """
  end

  # -- Docs groups -----------------------------------------------------------

  # Every documented eevm module mapped to its docs group. ExDoc puts a module
  # in the first group that matches it.
  defp module_groups do
    groups = Mix.Project.config()[:docs][:groups_for_modules]
    {:ok, modules} = :application.get_key(:eevm, :modules)

    for module <- modules,
        match?({:docs_v1, _, _, _, %{}, _, _}, Code.fetch_docs(module)),
        into: %{} do
      case Enum.find(groups, fn {_, matchers} -> Enum.any?(matchers, &matches?(&1, module)) end) do
        {group, _} -> {module, group}
        nil -> {module, :ungrouped}
      end
    end
  end

  defp matches?(%Regex{} = regex, module), do: Regex.match?(regex, inspect(module))
  defp matches?(matcher, module), do: matcher == module

  # -- Texts -----------------------------------------------------------------

  # {page, module the text belongs to (for local refs), text}
  defp public_texts(groups) do
    extras =
      for extra <- Mix.Project.config()[:docs][:extras],
          path = if(is_tuple(extra), do: elem(extra, 0), else: extra),
          String.ends_with?(path, ".md"),
          path not in @contributor_extras,
          do: {path, nil, File.read!(path)}

    docs =
      for {module, group} <- groups,
          group in @public_groups,
          {:docs_v1, _, _, _, moduledoc, _, entries} = Code.fetch_docs(module),
          text <- [
            doc_text(moduledoc) | for(entry <- entries, live?(entry), do: entry_text(entry))
          ],
          text != nil,
          do: {inspect(module), module, text}

    extras ++ docs
  end

  defp doc_text(%{"en" => text}), do: text
  defp doc_text(_), do: nil

  defp entry_text({_, _, _, doc, _}), do: doc_text(doc)

  # A documented entry that isn't itself deprecated: a deprecated function's
  # doc names its replacement and may mention other deprecated API.
  defp live?({_, _, _, %{"en" => _}, meta}), do: not Map.has_key?(meta, :deprecated)
  defp live?(_), do: false

  # Drops passages about a deprecation: sections under a heading that says
  # so, and paragraphs that say so.
  defp live_passages(text) do
    text
    |> String.split(~r/^(?=#+ )/m)
    |> Enum.reject(&(&1 |> String.split("\n", parts: 2) |> hd() |> deprecation?()))
    |> Enum.flat_map(&String.split(&1, ~r/\n\s*\n/))
    |> Enum.reject(&deprecation?/1)
  end

  defp deprecation?(text), do: text =~ ~r/deprecat/i

  # -- References --------------------------------------------------------------

  # Qualified references anywhere (prose or code), plus the short forms ExDoc
  # resolves in backticks: `fun/arity` in the current module and
  # `Alias.fun/arity` for an eevm module with a unique last segment.
  defp references(text, current, modules) do
    passages = live_passages(text)

    qualified =
      for passage <- passages,
          [name | fun] <-
            Regex.scan(~r/\b(EEVM(?:\.[A-Z]\w*)*)(?:\.([a-z_]\w*[?!]?))?/, passage,
              capture: :all_but_first
            ),
          module = Module.concat([name]),
          module in modules,
          do: qualified_ref(module, name, fun, passage)

    short =
      for passage <- passages,
          [_, token] <- Regex.scan(~r/`(?:[tcm]:)?([^`\s]+)`/, passage),
          not String.starts_with?(token, "EEVM"),
          ref = short_ref(token, current, modules),
          ref != nil,
          do: ref

    Enum.uniq(qualified ++ short)
  end

  defp qualified_ref(module, _name, [], _passage), do: {:module, module}

  defp qualified_ref(module, name, [fun], passage),
    do: {:fun, module, String.to_atom(fun), arity(passage, name, fun)}

  defp arity(passage, name, fun) do
    case Regex.run(~r/#{Regex.escape(name <> "." <> fun)}\/(\d+)/, passage) do
      [_, arity] -> String.to_integer(arity)
      nil -> :any
    end
  end

  defp short_ref(token, current, modules) do
    case Regex.run(~r/^(?:([A-Z]\w*(?:\.[A-Z]\w*)*)\.)?([a-z_]\w*[?!]?)\/(\d+)$/, token) do
      [_, "", fun, arity] when current != nil ->
        {:fun, current, String.to_atom(fun), String.to_integer(arity)}

      [_, alias_name, fun, arity] when alias_name != "" ->
        with module when module != nil <- resolve_alias(alias_name, modules),
             do: {:fun, module, String.to_atom(fun), String.to_integer(arity)}

      _ ->
        if token =~ ~r/^[A-Z]\w*(\.[A-Z]\w*)*$/,
          do:
            with(
              module when module != nil <- resolve_alias(token, modules),
              do: {:module, module}
            )
    end
  end

  defp resolve_alias(name, modules) do
    case Enum.filter(modules, &String.ends_with?(inspect(&1), "." <> name)) do
      [module] -> module
      _ -> nil
    end
  end

  defp ref_module({:module, module}), do: module
  defp ref_module({:fun, module, _, _}), do: module

  defp format_ref({:module, module}), do: inspect(module)
  defp format_ref({:fun, module, fun, :any}), do: "#{inspect(module)}.#{fun}"
  defp format_ref({:fun, module, fun, arity}), do: "#{inspect(module)}.#{fun}/#{arity}"

  defp problem(ref, groups) do
    module = ref_module(ref)

    case {Map.fetch!(groups, module), ref} do
      {:Deprecated, _} -> "#{inspect(module)} is deprecated"
      {:Internals, {:fun, _, _, _}} -> "#{inspect(module)} is in Internals"
      {:Internals, {:module, _}} -> nil
      _ -> deprecated_fun(ref)
    end
  end

  defp deprecated_fun({:module, _}), do: nil

  defp deprecated_fun({:fun, module, fun, arity}) do
    {:docs_v1, _, _, _, _, _, entries} = Code.fetch_docs(module)

    arities =
      for {{kind, ^fun, a}, _, _, _, meta} <- entries,
          kind in [:function, :macro],
          arity == :any or a == arity,
          do: Map.has_key?(meta, :deprecated)

    if arities != [] and Enum.all?(arities), do: "deprecated"
  end
end
