defmodule EEVM.Precompiles.BLS12MapFp2ToG2 do
  @moduledoc "Precompile 0x11 — BLS12-381 Fp2-to-G2 map. Delegates to `Bls12381.execute_map_fp2_to_g2/2`."
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.Bls12381

  @impl true
  def execute(input, gas_limit), do: Bls12381.execute_map_fp2_to_g2(input, gas_limit)
end
