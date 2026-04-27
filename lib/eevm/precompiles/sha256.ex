defmodule EEVM.Precompiles.SHA256 do
  @moduledoc """
  SHA-256 precompile at `0x02`. Returns the 32-byte digest. Gas: 60 + 12/word
  (Yellow Paper §E.2). Backed by `:crypto.hash/2` (OpenSSL).
  """

  @behaviour EEVM.Precompile

  @base_cost 60
  @word_cost 12

  @doc """
  Returns SHA-256 of `input` after charging `60 + 12 * ceil(len/32)`.

      iex> {:ok, digest, _gas} = EEVM.Precompiles.SHA256.execute(<<>>, 1_000)
      iex> byte_size(digest)
      32

      iex> EEVM.Precompiles.SHA256.execute(<<1::256>>, 5)
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
      {:ok, :crypto.hash(:sha256, input), cost}
    end
  end

  defp word_count(input), do: div(byte_size(input) + 31, 32)
end
