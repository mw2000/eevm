defmodule EEVM.Precompiles.BLS12MapFpToG1 do
  @moduledoc "Precompile 0x10 — BLS12-381 Fp-to-G1 map. Delegates to `Bls12381.execute_map_fp_to_g1/2`."
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.Bls12381

  @impl true
  def execute(input, gas_limit), do: Bls12381.execute_map_fp_to_g1(input, gas_limit)
end
