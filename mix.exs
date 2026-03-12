defmodule EEVM.MixProject do
  use Mix.Project

  def project do
    [
      app: :eevm,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_deps: :app_tree,
        plt_add_apps: [:ex_unit, :mix],
        ignore_warnings: "dialyzer_ignore.exs",
        list_unused_filters: true
      ],
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      # Keccak-256 hash (Ethereum uses Keccak, not SHA3-256)
      {:ex_keccak, "~> 0.7"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end
end
