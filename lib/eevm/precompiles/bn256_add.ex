defmodule EEVM.Precompiles.BN256Add do
  @moduledoc false
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.BN256

  @impl true
  def execute(input, gas_limit), do: BN256.execute_add(input, gas_limit)
end
