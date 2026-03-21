defmodule EEVM.Precompiles.Identity do
  @moduledoc """
  Identity precompile — address `0x04`.

  ## EVM Concepts

  The identity precompile is the simplest of the built-in contracts: it returns
  its input bytes unchanged. Despite that triviality, it is one of the most
  frequently called precompiles on mainnet because **Solidity uses it to copy
  memory regions via an inline `CALL`**. The `memcpy` assembly pattern in many
  contracts looks like:

  ```
  assembly { pop(call(gas(), 0x04, 0, src, len, dst, len)) }
  ```

  This works because CALL writes the return data directly into the specified
  output memory range, giving Solidity a cheap, predictable copy primitive that
  does not require a custom opcode.

  ### Gas schedule (Yellow Paper §E.2)

  | Component | Cost |
  |-----------|------|
  | Base      | 15   |
  | Per word  | 3 (one word = 32 bytes, rounded up) |

  An empty input costs the 15-gas base with no word component.

  ## Elixir Learning Notes

  - `div(n + 31, 32)` is the idiomatic ceiling-division-by-32 pattern. Adding
    `(divisor - 1)` before integer-dividing avoids a conditional while keeping
    the expression branchless.
  - The function returns a tagged tuple — `{:ok, output, gas_used}` on success
    and `{:error, :out_of_gas}` on failure — following the same convention used
    throughout the opcode modules.
  """

  @behaviour EEVM.Precompile

  @base_cost 15
  @word_cost 3

  @doc """
  Executes the identity precompile.

  Returns the input bytes unchanged after verifying that the caller supplied
  enough gas. Word count is `ceil(byte_size(input) / 32)`.

  ## Examples

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

  # ceil(byte_size / 32) via the (n + 31) / 32 trick.
  defp word_count(input), do: div(byte_size(input) + 31, 32)
end
