defmodule EEVM.Precompiles.BLS12G1Add do
  @moduledoc "Precompile 0x0B — BLS12-381 G1 point addition. Delegates to `Bls12381.execute_g1_add/2`."
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.Bls12381

  @impl true
  def execute(input, gas_limit), do: Bls12381.execute_g1_add(input, gas_limit)
end
