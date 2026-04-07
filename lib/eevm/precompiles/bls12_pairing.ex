defmodule EEVM.Precompiles.BLS12Pairing do
  @moduledoc "Precompile 0x0F — BLS12-381 pairing check. Delegates to `Bls12381.execute_pairing/2`."
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.Bls12381

  @impl true
  def execute(input, gas_limit), do: Bls12381.execute_pairing(input, gas_limit)
end
