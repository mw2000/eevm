defmodule EEVM.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mw2000/eevm"

  def project do
    [
      app: :eevm,
      name: "eevm",
      version: @version,
      elixir: "~> 1.18",
      description: "Ethereum Virtual Machine implementation in Elixir.",
      source_url: @source_url,
      homepage_url: @source_url,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: [
        plt_add_deps: :app_tree,
        plt_add_apps: [:ex_unit, :mix],
        ignore_warnings: "dialyzer_ignore.exs",
        list_unused_filters: true
      ],
      aliases: aliases(),
      docs: docs()
    ]
  end

  def cli do
    [
      preferred_envs: [
        bench: :prod,
        dialyzer: :dev,
        docs: :dev,
        "eevm.state_tests": :test,
        "eevm.blockchain_tests": :test,
        "hex.publish": :dev
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_rlp, "~> 0.6.0"},
      {:ex_secp256k1, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:rustler, "~> 0.36", runtime: false},
      # Optional so projects that depend on eevm never fetch it; :prod so `mix bench`
      # measures the build users run.
      {:benchee, "~> 1.3", only: [:dev, :prod], runtime: false, optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      bench: &bench/1,
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "cmd mix test"
      ]
    ]
  end

  # `mix bench` runs every bench/*_bench.exs suite except state_fixtures, which needs the
  # ethereum-tests submodule; `mix bench interpreter state_fixtures` runs only the named ones.
  defp bench(suites) do
    Mix.Task.run("app.start")

    files =
      case suites do
        [] -> Path.wildcard("bench/*_bench.exs") -- ["bench/state_fixtures_bench.exs"]
        names -> Enum.map(names, &"bench/#{&1}_bench.exs")
      end

    Enum.each(files, &Code.require_file/1)
  end

  defp docs do
    [
      main: "EEVM",
      source_url: @source_url,
      source_ref: "main",
      extras: [
        "README.md",
        "guides/database_adapters.md",
        {"bench/README.md", filename: "benchmarks", title: "Benchmarks"},
        "LICENSE"
      ],
      # Public API first, then extension points; everything under
      # "Internals" is an implementation detail and may change in any release.
      groups_for_modules: [
        "Getting started": [
          EEVM,
          EEVM.CallResult,
          EEVM.Config,
          EEVM.Error,
          EEVM.BlockEnv,
          EEVM.TxEnv
        ],
        Transactions: [
          EEVM.Handler,
          EEVM.TransactionResult,
          ~r/^EEVM\.Transaction\.(Legacy|AccessList|FeeMarket|Blob|SetCode|Authorization)$/,
          EEVM.Transaction,
          EEVM.Transaction.Envelope,
          EEVM.Transaction.Signer
        ],
        Blocks: [
          EEVM.Block,
          EEVM.Block.Header,
          EEVM.Block.Withdrawal,
          EEVM.Block.Receipt,
          EEVM.Block.Result
        ],
        State: [
          EEVM.Database,
          EEVM.Database.InMemory,
          EEVM.Database.ReadError,
          EEVM.StateChanges,
          EEVM.StateRoot
        ],
        Extending: [
          EEVM.Precompile,
          EEVM.Tracer,
          EEVM.Tracer.TraceStep,
          EEVM.Block.Processor,
          EEVM.Block.Requests,
          EEVM.Block.Bloom,
          ~r/^EEVM\.SystemContracts\./
        ],
        Deprecated: [EEVM.Context.Block, EEVM.Context.Transaction, EEVM.Database.Legacy],
        Internals: [~r/^EEVM\./]
      ]
    ]
  end
end
