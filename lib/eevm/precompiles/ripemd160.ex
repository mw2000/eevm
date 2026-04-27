defmodule EEVM.Precompiles.RIPEMD160 do
  @moduledoc """
  RIPEMD-160 precompile at `0x03`. Returns the 20-byte digest **right-aligned
  in 32 bytes** (12 zero bytes prepended). Gas: 600 + 120/word. Backed by
  `:crypto.hash/2` (OpenSSL).
  """

  @behaviour EEVM.Precompile

  @base_cost 600
  @word_cost 120

  @doc """
  Returns `<<0::96, RIPEMD160(input)::binary>>` after charging
  `600 + 120 * ceil(len/32)`.

      iex> {:ok, out, _gas} = EEVM.Precompiles.RIPEMD160.execute(<<>>, 10_000)
      iex> byte_size(out)
      32
      iex> binary_part(out, 0, 12)
      <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>

      iex> EEVM.Precompiles.RIPEMD160.execute(<<1::256>>, 5)
      {:error, :out_of_gas}
  """
  @spec execute(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :out_of_gas}
  @impl true
  def execute(input, gas_limit) do
    cost = @base_cost + @word_cost * word_count(input)

    if cost > gas_limit do
      {:error, :out_of_gas}
    else
      hash = :crypto.hash(:ripemd160, input)
      {:ok, <<0::96, hash::binary>>, cost}
    end
  end

  defp word_count(input), do: div(byte_size(input) + 31, 32)
end
