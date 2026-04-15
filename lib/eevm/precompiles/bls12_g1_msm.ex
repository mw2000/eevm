defmodule EEVM.Precompiles.BLS12G1MSM do
  @moduledoc "Precompile 0x0C — BLS12-381 G1 multiscalar multiplication. Delegates to `Bls12381.execute_g1_msm/2`."
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.Bls12381

  @impl true
  def execute(input, gas_limit), do: Bls12381.execute_g1_msm(input, gas_limit)
end
