defmodule EEVM.Gas do
  @moduledoc """
  Gas costs for EVM opcodes and memory expansion.

  Backwards-compatible facade over static, dynamic, and memory gas modules.
  """

  alias EEVM.Gas.{Dynamic, Memory, Static}

  @gas_call_value 9000
  @gas_new_account 25_000

  @spec static_cost(non_neg_integer()) :: non_neg_integer()
  defdelegate static_cost(opcode), to: Static

  @spec exp_dynamic_cost(non_neg_integer()) :: non_neg_integer()
  defdelegate exp_dynamic_cost(exponent), to: Dynamic

  @spec keccak256_dynamic_cost(non_neg_integer()) :: non_neg_integer()
  defdelegate keccak256_dynamic_cost(size), to: Dynamic

  @spec copy_cost(non_neg_integer()) :: non_neg_integer()
  defdelegate copy_cost(size), to: Dynamic

  @spec log_cost(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defdelegate log_cost(topic_count, data_size), to: Dynamic

  @spec create2_hash_cost(non_neg_integer()) :: non_neg_integer()
  defdelegate create2_hash_cost(init_code_size), to: Dynamic

  @spec code_deposit_cost(non_neg_integer()) :: non_neg_integer()
  defdelegate code_deposit_cost(code_size), to: Dynamic

  @spec call_value_cost(non_neg_integer()) :: non_neg_integer()
  def call_value_cost(0), do: 0
  def call_value_cost(_value), do: @gas_call_value

  @spec call_new_account_cost(boolean(), non_neg_integer()) :: non_neg_integer()
  def call_new_account_cost(_exists?, 0), do: 0
  def call_new_account_cost(true, _value), do: 0
  def call_new_account_cost(false, _value), do: @gas_new_account

  @spec call_forwarded_gas(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def call_forwarded_gas(available_gas, requested_gas) do
    max_forward = available_gas - div(available_gas, 64)
    min(requested_gas, max_forward)
  end

  @spec call_stipend(non_neg_integer()) :: non_neg_integer()
  def call_stipend(0), do: 0
  def call_stipend(_value), do: 2300

  @spec memory_expansion_cost(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defdelegate memory_expansion_cost(current_size, offset, length), to: Memory

  @spec memory_expansion_cost_word(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defdelegate memory_expansion_cost_word(current_size, offset), to: Memory

  @spec memory_expansion_cost_byte(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defdelegate memory_expansion_cost_byte(current_size, offset), to: Memory
end
