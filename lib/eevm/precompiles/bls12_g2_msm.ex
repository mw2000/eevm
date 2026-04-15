defmodule EEVM.Precompiles.BLS12G2MSM do
  @moduledoc "Precompile 0x0E — BLS12-381 G2 multiscalar multiplication. Delegates to `Bls12381.execute_g2_msm/2`."
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.Bls12381

  @impl true
  def execute(input, gas_limit), do: Bls12381.execute_g2_msm(input, gas_limit)
end
