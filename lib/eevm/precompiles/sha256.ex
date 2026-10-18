defmodule EEVM.Precompiles.SHA256 do
  @moduledoc """
  SHA-256 precompile — address `0x02`.

  ### Gas schedule (Yellow Paper §E.2)

  | Component | Cost |
  |-----------|------|
  | Base      | 60   |
  | Per word  | 12 (one word = 32 bytes, rounded up) |

  ### Output format

  Always 32 bytes — the raw SHA-256 digest.
  """

  @behaviour EEVM.Precompile

  @base_cost 60
  @word_cost 12

  @doc """
  Executes the SHA-256 precompile.

  Hashes `input` with SHA-256 and returns the 32-byte digest, charging
  `60 + 12 * ceil(byte_size(input) / 32)` gas.

  ## Examples

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

  # ceil(byte_size / 32) via the (n + 31) / 32 trick.
  defp word_count(input), do: div(byte_size(input) + 31, 32)
end
