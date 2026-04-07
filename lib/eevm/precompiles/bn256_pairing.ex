defmodule EEVM.Precompiles.BN256Pairing do
  @moduledoc "Precompile 0x08 — BN256 pairing check. Delegates to `BN256.execute_pairing/2`."
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.BN256

  @impl true
  def execute(input, gas_limit), do: BN256.execute_pairing(input, gas_limit)
end
