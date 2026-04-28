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
        dialyzer: :dev,
        docs: :dev,
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
      {:ex_keccak, "~> 0.7"},
      {:ex_secp256k1, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:bn, "~> 0.2.2"},
      {:rustler, "~> 0.36", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "cmd mix test"
      ]
    ]
  end

  defp docs do
    [
      main: "EEVM",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "LICENSE"],
      groups_for_modules: [
        Interpreter: [~r/^EEVM\.Interpreter($|\.)/],
        Instructions: [~r/^EEVM\.Interpreter\.Instructions/],
        Precompiles: [~r/^EEVM\.Precompile($|s)/],
        Block: [~r/^EEVM\.Block($|\.)/],
        Transaction: [~r/^EEVM\.Transaction($|\.)/],
        Context: [~r/^EEVM\.Context($|\.)/],
        "System Contracts": [~r/^EEVM\.SystemContracts($|\.)/],
        "State & Storage": [
          EEVM.Database,
          EEVM.Database.InMemory,
          EEVM.Storage,
          EEVM.WorldState,
          EEVM.StateRoot,
          ~r/^EEVM\.MPT($|\.)/
        ],
        Gas: [~r/^EEVM\.Gas($|\.)/, EEVM.HardforkConfig]
      ]
    ]
  end
end
