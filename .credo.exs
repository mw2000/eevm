%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "mix.exs"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      color: true,
      checks: [
        {Credo.Check.Readability.MaxLineLength, max_length: 120},
        {Credo.Check.Readability.PredicateFunctionNames, false},
        {Credo.Check.Readability.WithSingleClause, false},
        {Credo.Check.Readability.AliasOrder, false},
        {Credo.Check.Refactor.Nesting, false},
        {Credo.Check.Refactor.CyclomaticComplexity, false},
        {Credo.Check.Refactor.FunctionArity, false},
        {Credo.Check.Readability.ModuleDoc, false}
      ]
    }
  ]
}
