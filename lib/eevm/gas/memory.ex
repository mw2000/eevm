defmodule EEVM.Gas.Memory do
  @moduledoc """
  Memory expansion gas cost calculation.

  EVM memory is a byte-addressable array that starts empty and expands on demand.
  Expanding memory is not free — the cost grows quadratically to discourage excessive
  memory usage.

  ## Formula (Yellow Paper, Appendix H)

      cost(words) = 3 × words + words² ÷ 512

  where `words = ceil(byte_size / 32)`.

  The expansion cost is the difference between the cost at the new size and the cost
  at the current size. If the access fits within already-allocated memory, the cost is 0.

  ## Example

      # Expanding from 0 to 32 bytes (1 word): 3×1 + 1²/512 = 3 gas
      # Expanding from 0 to 1024 bytes (32 words): 3×32 + 32²/512 = 98 gas
      # Expanding from 0 to 32768 bytes (1024 words): 3×1024 + 1024²/512 = 5120 gas

  The quadratic term makes very large memory allocations prohibitively expensive,
  providing a natural bound on memory usage.
  """

  # Linear coefficient: 3 gas per 32-byte word (Yellow Paper)
  @gas_memory 3

  @spec memory_expansion_cost(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def memory_expansion_cost(_current_size, _offset, 0), do: 0

  def memory_expansion_cost(current_size, offset, length) do
    needed = offset + length
    new_size = word_ceil(needed) * 32

    if new_size <= current_size do
      0
    else
      old_words = div(current_size, 32)
      new_words = div(new_size, 32)
      memory_cost(new_words) - memory_cost(old_words)
    end
  end

  @spec memory_expansion_cost_word(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def memory_expansion_cost_word(current_size, offset),
    do: memory_expansion_cost(current_size, offset, 32)

  @spec memory_expansion_cost_byte(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def memory_expansion_cost_byte(current_size, offset),
    do: memory_expansion_cost(current_size, offset, 1)

  defp memory_cost(word_count), do: @gas_memory * word_count + div(word_count * word_count, 512)

  defp word_ceil(0), do: 0
  defp word_ceil(byte_size), do: div(byte_size + 31, 32)
end
