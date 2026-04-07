defmodule EEVM.Precompiles.BLS12G2Add do
  @moduledoc "Precompile 0x0D — BLS12-381 G2 point addition. Delegates to `Bls12381.execute_g2_add/2`."
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.Bls12381

  @impl true
  def execute(input, gas_limit), do: Bls12381.execute_g2_add(input, gas_limit)
end
