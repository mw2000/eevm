defmodule EEVM.Transaction.IntrinsicGas do
  @moduledoc """
  Intrinsic transaction gas calculation.

  ## EVM Concepts

  Before EVM bytecode starts executing, every transaction pays an upfront
  intrinsic gas cost. This covers the base transaction envelope plus static
  costs derived from calldata, contract creation, and access-list entries.

  This module implements the cost components needed by transaction validation.

  ## Elixir Learning Notes

  - `Enum.reduce/3` is used to accumulate byte and access-list costs.
  - We compute `ceil(n / 32)` with integer arithmetic as `div(n + 31, 32)`.
  """

  alias EEVM.Context.Transaction

  @tx_base_cost 21_000
  @tx_data_zero_cost 4
  @tx_data_non_zero_cost 16
  @tx_create_cost 32_000
  @initcode_word_cost 2
  @access_list_address_cost 2_400
  @access_list_storage_key_cost 1_900

  @spec calculate(Transaction.t()) :: non_neg_integer()
  def calculate(%Transaction{} = tx) do
    @tx_base_cost +
      calldata_cost(tx.data) +
      creation_cost(tx) +
      access_list_cost(tx.access_list)
  end

  defp calldata_cost(data) when is_binary(data) do
    for <<byte <- data>>, reduce: 0 do
      acc -> acc + if(byte == 0, do: @tx_data_zero_cost, else: @tx_data_non_zero_cost)
    end
  end

  defp creation_cost(%Transaction{to: nil, data: initcode}) do
    @tx_create_cost + @initcode_word_cost * word_count(initcode)
  end

  defp creation_cost(%Transaction{}), do: 0

  defp word_count(data), do: div(byte_size(data) + 31, 32)

  defp access_list_cost(access_list) do
    Enum.reduce(access_list, 0, fn {_address, slot_keys}, acc ->
      acc + @access_list_address_cost + @access_list_storage_key_cost * length(slot_keys)
    end)
  end
end
