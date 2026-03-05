defmodule EEVM.MixProject do
  use Mix.Project

  def project do
    [
      app: :eevm,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:ex_keccak, "~> 0.7"}
    ]
  end
end
