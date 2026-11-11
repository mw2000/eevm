defmodule Devx.MixProject do
  use Mix.Project

  # A library user's project: it depends on eevm by path and uses only what
  # the public docs describe. See README.md.
  def project do
    [
      app: :devx,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:eevm, path: "../.."}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
