defmodule EEVM.Precompiles.ModExpEIP7883 do
  @moduledoc "Precompile 0x05 from Osaka — ModExp with EIP-7883 pricing. Delegates to `ModExp.execute/3`."
  @behaviour EEVM.Precompile

  alias EEVM.Precompiles.ModExp

  @doc """
  Executes the ModExp precompile with EIP-7883 pricing.
  """
  @spec execute(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :out_of_gas}
  @impl true
  def execute(input, gas_limit), do: ModExp.execute(input, gas_limit, :eip_7883)
end
