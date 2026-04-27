defmodule EEVM.Precompiles.Identity do
  @moduledoc """
  Identity precompile at `0x04`. Returns input unchanged. Gas: 15 + 3/word
  (Yellow Paper §E.2). Heavily used by Solidity as an inline `memcpy` via
  `call(gas(), 0x04, 0, src, len, dst, len)`.
  """

  @behaviour EEVM.Precompile

  @base_cost 15
  @word_cost 3

  @doc """
  Returns `input` unchanged after charging `15 + 3 * ceil(len/32)`.

      iex> EEVM.Precompiles.Identity.execute(<<>>, 1_000)
      {:ok, <<>>, 15}

      iex> EEVM.Precompiles.Identity.execute(<<"hello">>, 1_000)
      {:ok, <<"hello">>, 18}

      iex> EEVM.Precompiles.Identity.execute(<<1::256>>, 5)
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
      {:ok, input, cost}
    end
  end

  defp word_count(input), do: div(byte_size(input) + 31, 32)
end
