defmodule EEVM.Precompiles do
  @moduledoc false

  alias EEVM.Precompiles.ECRecover
  alias EEVM.Precompiles.Identity
  alias EEVM.Precompiles.Blake2F
  alias EEVM.Precompiles.ModExp
  alias EEVM.Precompiles.RIPEMD160
  alias EEVM.Precompiles.SHA256

  @spec is_precompile?(non_neg_integer()) :: boolean()
  def is_precompile?(address) when address >= 0x01 and address <= 0x0A, do: true
  def is_precompile?(_), do: false

  @spec execute(non_neg_integer(), binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute(0x01, input, gas_limit), do: ECRecover.execute(input, gas_limit)
  def execute(0x02, input, gas_limit), do: SHA256.execute(input, gas_limit)
  def execute(0x03, input, gas_limit), do: RIPEMD160.execute(input, gas_limit)
  def execute(0x04, input, gas_limit), do: Identity.execute(input, gas_limit)
  def execute(0x05, input, gas_limit), do: ModExp.execute(input, gas_limit)
  def execute(0x09, input, gas_limit), do: Blake2F.execute(input, gas_limit)

  def execute(address, input, gas_limit) do
    :erlang.apply(__MODULE__, :do_execute, [address, input, gas_limit])
  end

  def do_execute(_address, _input, _gas_limit) do
    {:error, :not_implemented}
  end
end
