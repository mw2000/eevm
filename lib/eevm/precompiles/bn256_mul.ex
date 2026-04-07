defmodule EEVM.Precompiles.BN256Mul do
  @moduledoc "Precompile 0x07 — BN256 scalar multiplication. Delegates to `BN256.execute_mul/2`."
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.BN256

  @impl true
  def execute(input, gas_limit), do: BN256.execute_mul(input, gas_limit)
end
