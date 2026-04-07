defmodule EEVM.Precompiles.BN256Add do
  @moduledoc "Precompile 0x06 — BN256 point addition. Delegates to `BN256.execute_add/2`."
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.BN256

  @impl true
  def execute(input, gas_limit), do: BN256.execute_add(input, gas_limit)
end
