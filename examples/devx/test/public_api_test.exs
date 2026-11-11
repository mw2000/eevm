defmodule Devx.PublicApiTest do
  @moduledoc """
  The examples call only eevm's public API: every eevm function the compiled
  `Devx.*` modules call or capture is in a public docs group of eevm's
  `mix.exs` (Getting started, Transactions, Blocks, State, Extending) and
  isn't deprecated. Like `test/purity_test.exs` in eevm, it reads the remote
  calls compiled into each module, so aliases and imports can't hide one.
  """
  use ExUnit.Case, async: true

  @public_groups [:"Getting started", :Transactions, :Blocks, :State, :Extending]

  test "the examples call only public, non-deprecated eevm functions" do
    groups = eevm_doc_groups()

    calls =
      for module <- Application.spec(:devx, :modules),
          {target, fun, arity} <- remote_calls(module),
          String.starts_with?(Atom.to_string(target), "Elixir.EEVM"),
          uniq: true,
          do: {module, {target, fun, arity}}

    assert calls != [], "found no eevm calls; is the check reading the right modules?"

    problems =
      for {module, {target, fun, arity} = call} <- calls,
          problem = problem(group(groups, target), call),
          do: "#{inspect(module)} calls #{inspect(target)}.#{fun}/#{arity}: #{problem}"

    assert problems == [], Enum.join(problems, "\n")
  end

  defp problem(group, _call) when group not in @public_groups,
    do: "#{group || "an undocumented module"}, not public API"

  defp problem(_group, {target, fun, arity}) do
    {:docs_v1, _, _, _, _, _, entries} = Code.fetch_docs(target)

    case Enum.find(entries, &documents?(&1, fun, arity)) do
      {_, _, _, :hidden, _} -> "hidden (@doc false)"
      {_, _, _, _, %{deprecated: message}} -> "deprecated: #{message}"
      nil -> "undocumented"
      _ -> nil
    end
  end

  # A doc entry also covers the lower arities its default arguments generate.
  defp documents?({{kind, fun, max}, _, _, _, meta}, fun, arity) when kind in [:function, :macro],
    do: arity in (max - Map.get(meta, :defaults, 0))..max

  defp documents?(_entry, _fun, _arity), do: false

  # eevm's docs groups, read from its mix.exs. ExDoc puts a module in the
  # first group that matches it.
  defp eevm_doc_groups do
    Mix.Project.in_project(:eevm, Mix.Project.deps_paths()[:eevm], fn _ ->
      Mix.Project.config()[:docs][:groups_for_modules]
    end)
  end

  defp group(groups, module) do
    Enum.find_value(groups, fn {group, matchers} ->
      if Enum.any?(matchers, &matches?(&1, module)), do: group
    end)
  end

  defp matches?(%Regex{} = regex, module), do: Regex.match?(regex, inspect(module))
  defp matches?(matcher, module), do: matcher == module

  # Remote calls (the import table) plus `&Mod.fun/arity` captures (in the
  # debug info), which the import table leaves out.
  defp remote_calls(module) do
    beam = :code.which(module)
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])

    {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(beam, [:debug_info])

    {:ok, forms} = backend.debug_info(:erlang_v1, module, data, [])
    imports ++ fun_refs(forms, [])
  end

  defp fun_refs({:fun, _, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}}, acc),
    do: [{m, f, a} | acc]

  defp fun_refs(tuple, acc) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> fun_refs(acc)
  defp fun_refs(list, acc) when is_list(list), do: Enum.reduce(list, acc, &fun_refs/2)
  defp fun_refs(_other, acc), do: acc
end
