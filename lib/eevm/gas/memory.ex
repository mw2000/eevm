defmodule EEVM.Gas.Memory do
  @moduledoc false

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
