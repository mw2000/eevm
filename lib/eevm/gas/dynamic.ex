defmodule EEVM.Gas.Dynamic do
  @moduledoc false

  import Bitwise

  @gas_exp_byte 50
  @gas_keccak256_word 6
  @gas_copy 3
  @gas_log 375
  @gas_log_topic 375
  @gas_log_data 8
  @gas_create2_word 6
  @gas_code_deposit 200

  @spec exp_dynamic_cost(non_neg_integer()) :: non_neg_integer()
  def exp_dynamic_cost(0), do: 0

  def exp_dynamic_cost(exponent) do
    @gas_exp_byte * byte_size_of(exponent)
  end

  @spec keccak256_dynamic_cost(non_neg_integer()) :: non_neg_integer()
  def keccak256_dynamic_cost(size), do: @gas_keccak256_word * word_count(size)

  @spec copy_cost(non_neg_integer()) :: non_neg_integer()
  def copy_cost(size), do: div(size + 31, 32) * @gas_copy

  @spec log_cost(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def log_cost(topic_count, data_size),
    do: @gas_log + @gas_log_topic * topic_count + @gas_log_data * data_size

  @spec create2_hash_cost(non_neg_integer()) :: non_neg_integer()
  def create2_hash_cost(init_code_size), do: word_count(init_code_size) * @gas_create2_word

  @spec code_deposit_cost(non_neg_integer()) :: non_neg_integer()
  def code_deposit_cost(code_size), do: code_size * @gas_code_deposit

  defp word_count(0), do: 0
  defp word_count(byte_size), do: div(byte_size + 31, 32)

  defp byte_size_of(0), do: 0
  defp byte_size_of(n) when n > 0, do: div(floor_log256(n), 1) + 1

  defp floor_log256(n) when n > 0 do
    bit_length = do_bit_length(n, 0)
    div(bit_length - 1, 8)
  end

  defp do_bit_length(0, acc), do: acc
  defp do_bit_length(n, acc), do: do_bit_length(n >>> 1, acc + 1)
end
