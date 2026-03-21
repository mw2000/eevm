defmodule EEVM.Precompiles.BN256Pairing do
  @moduledoc false
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.BN256

  @impl true
  def execute(input, gas_limit), do: BN256.execute_pairing(input, gas_limit)
end
