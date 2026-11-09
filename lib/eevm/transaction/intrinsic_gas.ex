defmodule EEVM.Transaction.IntrinsicGas do
  @moduledoc """
  Intrinsic transaction gas calculation.

  Covers the base transaction envelope plus static costs derived from
  calldata, contract creation, access-list entries, and EIP-7702
  authorizations — the upfront gas charged before EVM execution begins.
  """

  alias EEVM.Context.Transaction
  alias EEVM.Gas.Intrinsic, as: Intrinsic
  alias EEVM.HardforkConfig

  @tx_base_cost 21_000
  @tx_create_cost 32_000
  @initcode_word_cost 2
  @access_list_address_cost 2_400
  @access_list_storage_key_cost 1_900
  # EIP-7702: charged per authorization, partly refunded for existing authorities.
  @per_empty_account_cost 25_000

  @doc """
  Returns the intrinsic gas of `tx` under `hardfork`: the 21,000 base, its
  calldata, contract creation (32,000 from Homestead, EIP-2, plus 2 per
  initcode word from Shanghai, EIP-3860), access-list entries (EIP-2930), and
  25,000 per authorization (EIP-7702).
  """
  @spec calculate(Transaction.t(), HardforkConfig.t()) :: non_neg_integer()
  def calculate(%Transaction{} = tx, %HardforkConfig{} = hardfork) do
    @tx_base_cost +
      Intrinsic.calldata_cost(tx.data, hardfork) +
      creation_cost(tx, hardfork) +
      access_list_cost(tx.access_list) +
      @per_empty_account_cost * length(tx.authorization_list)
  end

  @doc "EIP-7623 calldata floor from Prague, 0 before."
  @spec calldata_floor_gas_cost(Transaction.t(), HardforkConfig.t()) :: non_neg_integer()
  def calldata_floor_gas_cost(%Transaction{} = tx, %HardforkConfig{} = hardfork) do
    if HardforkConfig.enabled?(hardfork, :eip_7623) do
      Intrinsic.calldata_floor_cost(tx.data)
    else
      0
    end
  end

  @doc "Lowest valid gas limit: the larger of intrinsic gas and the calldata floor."
  @spec minimum_gas_limit(Transaction.t(), HardforkConfig.t()) :: non_neg_integer()
  def minimum_gas_limit(%Transaction{} = tx, %HardforkConfig{} = hardfork) do
    max(calculate(tx, hardfork), calldata_floor_gas_cost(tx, hardfork))
  end

  defp creation_cost(%Transaction{to: nil, data: initcode}, hardfork) do
    create_cost = if HardforkConfig.enabled?(hardfork, :eip_2), do: @tx_create_cost, else: 0

    initcode_cost =
      if HardforkConfig.enabled?(hardfork, :eip_3860),
        do: @initcode_word_cost * word_count(initcode),
        else: 0

    create_cost + initcode_cost
  end

  defp creation_cost(%Transaction{}, _hardfork), do: 0

  defp word_count(data), do: div(byte_size(data) + 31, 32)

  defp access_list_cost(access_list) do
    Enum.reduce(access_list, 0, fn {_address, slot_keys}, acc ->
      acc + @access_list_address_cost + @access_list_storage_key_cost * length(slot_keys)
    end)
  end
end
