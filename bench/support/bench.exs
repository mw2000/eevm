defmodule EEVM.Bench do
  @moduledoc """
  Runs a Benchee suite whose jobs each spend a known amount of gas, then prints a
  gas-throughput table (gas/s = gas per run × runs per second), the number EVMs are
  usually compared by.
  """

  @doc """
  Benchmarks `jobs`, a map of scenario name to `{gas_per_run, fun}`.

  Callers measure `gas_per_run` by running the job once and checking its result, so a
  broken job fails before any timing starts.
  """
  @spec run(%{String.t() => {non_neg_integer(), (-> term())}}) :: Benchee.Suite.t()
  def run(jobs) do
    suite =
      jobs
      |> Map.new(fn {name, {_gas, fun}} -> {name, fun} end)
      |> Benchee.run(warmup: 1, time: 3, memory_time: 0.5, print: [configuration: false])

    width = jobs |> Map.keys() |> Enum.map(&String.length/1) |> Enum.max()
    IO.puts("\nGas throughput (MIX_ENV=#{Mix.env()}):\n")
    IO.puts("#{String.pad_trailing("Name", width)}   gas/run          ips      Mgas/s")

    for %{name: name, run_time_data: %{statistics: %{ips: ips}}} <-
          Enum.sort_by(suite.scenarios, & &1.name) do
      {gas, _fun} = Map.fetch!(jobs, name)

      IO.puts(
        String.pad_trailing(name, width) <>
          pad(gas, 10) <>
          pad(Float.round(ips, 2), 13) <> pad(Float.round(gas * ips / 1.0e6, 2), 12)
      )
    end

    suite
  end

  defp pad(value, width), do: value |> to_string() |> String.pad_leading(width)
end
