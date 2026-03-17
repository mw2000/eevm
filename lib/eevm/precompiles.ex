defmodule EEVM.Precompiles do
  @moduledoc false

  alias EEVM.Precompiles.RIPEMD160

  @spec is_precompile?(non_neg_integer()) :: boolean()
  def is_precompile?(address) when address >= 0x01 and address <= 0x0A, do: true
  def is_precompile?(_), do: false

  @spec execute(non_neg_integer(), binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute(0x03, input, gas_limit), do: RIPEMD160.execute(input, gas_limit)

  def execute(address, input, gas_limit) do
    :erlang.apply(__MODULE__, :do_execute, [address, input, gas_limit])
  end

  def do_execute(_address, _input, _gas_limit) do
    {:error, :not_implemented}
  end
end
