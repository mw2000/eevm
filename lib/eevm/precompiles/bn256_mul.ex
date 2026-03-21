defmodule EEVM.Precompiles.BN256Mul do
  @moduledoc false
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.BN256

  @impl true
  def execute(input, gas_limit), do: BN256.execute_mul(input, gas_limit)
end
