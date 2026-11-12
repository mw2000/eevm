defmodule EEVM.Gas.Intrinsic do
  @moduledoc """
  Intrinsic gas costs for transactions — costs that apply before execution begins.

  Two main components:

  - **Base cost**: 21,000 gas for a regular transaction.
  - **Calldata cost**: per-byte fee on the transaction's `data` field —
    4 gas per zero byte, 16 gas per non-zero byte (post-Istanbul / EIP-2028;
    pre-Istanbul, non-zero bytes cost 68 gas).
  """

  alias EEVM.HardforkConfig
  require EEVM.HardforkConfig

  @tx_base_gas 21_000
  # EIP-2028 (Istanbul): non-zero calldata reduced from 68 → 16 gas.
  @tx_data_zero_gas 4
  @tx_data_non_zero_gas 16
  @frontier_tx_data_non_zero_gas 68
  @tx_calldata_floor_token_cost 10

  @doc """
  Returns the intrinsic gas cost for zero-byte calldata.

  Per EIP-2028: 4 gas per zero byte.
  """
  @spec tx_data_zero_gas() :: non_neg_integer()
  def tx_data_zero_gas, do: @tx_data_zero_gas

  @doc """
  Returns the intrinsic gas cost for non-zero-byte calldata.

  Per EIP-2028 (Istanbul): 16 gas per non-zero byte (was 68 pre-Istanbul).
  """
  @spec tx_data_non_zero_gas() :: non_neg_integer()
  def tx_data_non_zero_gas, do: @tx_data_non_zero_gas

  @doc "Returns the Prague calldata floor gas charged per token."
  @spec tx_calldata_floor_token_cost() :: non_neg_integer()
  def tx_calldata_floor_token_cost, do: @tx_calldata_floor_token_cost

  @doc """
  Computes the total intrinsic calldata gas cost for the given binary.

  Iterates each byte: zero bytes cost `#{@tx_data_zero_gas}` gas,
  non-zero bytes cost `#{@tx_data_non_zero_gas}` gas from Istanbul (EIP-2028)
  and `#{@frontier_tx_data_non_zero_gas}` before.

  ## Examples

      iex> EEVM.Gas.Intrinsic.calldata_cost(<<>>, EEVM.HardforkConfig.new(:cancun))
      0

      iex> EEVM.Gas.Intrinsic.calldata_cost(<<0x00, 0xFF>>, EEVM.HardforkConfig.new(:istanbul))
      20

      iex> EEVM.Gas.Intrinsic.calldata_cost(<<0x00, 0xFF>>, EEVM.HardforkConfig.new(:constantinople))
      72

  """
  @spec calldata_cost(binary(), HardforkConfig.t()) :: non_neg_integer()
  def calldata_cost(data, %HardforkConfig{} = hardfork) when is_binary(data) do
    non_zero_gas =
      if HardforkConfig.enabled?(hardfork, :eip_2028),
        do: @tx_data_non_zero_gas,
        else: @frontier_tx_data_non_zero_gas

    for <<byte <- data>>, reduce: 0 do
      acc when byte == 0 -> acc + @tx_data_zero_gas
      acc -> acc + non_zero_gas
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
