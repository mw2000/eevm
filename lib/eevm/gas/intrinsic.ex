defmodule EEVM.Gas.Intrinsic do
  @moduledoc """
  Per-byte calldata costs and the EIP-7623 (Prague) calldata floor.

  Standard calldata cost: 4/zero-byte, 16/non-zero-byte (EIP-2028 Istanbul
  repricing of non-zero from 68). Floor cost: `21_000 + 10 * tokens`, where
  zero bytes count as 1 token and non-zero bytes as 4.
  """

  @tx_base_gas 21_000
  @tx_data_zero_gas 4
  @tx_data_non_zero_gas 16
  @tx_calldata_floor_token_cost 10

  @doc "Per-byte cost for zero calldata bytes (EIP-2028)."
  @spec tx_data_zero_gas() :: non_neg_integer()
  def tx_data_zero_gas, do: @tx_data_zero_gas

  @doc "Per-byte cost for non-zero calldata bytes (EIP-2028, post-Istanbul)."
  @spec tx_data_non_zero_gas() :: non_neg_integer()
  def tx_data_non_zero_gas, do: @tx_data_non_zero_gas

  @doc "EIP-7623 calldata floor cost per token."
  @spec tx_calldata_floor_token_cost() :: non_neg_integer()
  def tx_calldata_floor_token_cost, do: @tx_calldata_floor_token_cost

  @doc """
  Total calldata cost: 4 per zero byte, 16 per non-zero byte.

      iex> EEVM.Gas.Intrinsic.calldata_cost(<<>>)
      0

      iex> EEVM.Gas.Intrinsic.calldata_cost(<<0x00, 0xFF>>)
      20
  """
  @spec calldata_cost(binary()) :: non_neg_integer()
  def calldata_cost(data) when is_binary(data) do
    for <<byte <- data>>, reduce: 0 do
      acc when byte == 0 -> acc + @tx_data_zero_gas
      acc -> acc + @tx_data_non_zero_gas
    end
  end

  @doc "Counts EIP-7623 calldata floor tokens (zero=1, non-zero=4)."
  @spec calldata_floor_tokens(binary()) :: non_neg_integer()
  def calldata_floor_tokens(data) when is_binary(data) do
    for <<byte <- data>>, reduce: 0 do
      acc when byte == 0 -> acc + 1
      acc -> acc + 4
    end
  end

  @doc "Computes the Prague calldata floor gas cost for the given calldata."
  @spec calldata_floor_cost(binary()) :: non_neg_integer()
  def calldata_floor_cost(data) when is_binary(data) do
    @tx_base_gas + @tx_calldata_floor_token_cost * calldata_floor_tokens(data)
  end
end
