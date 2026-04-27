defmodule EEVM.Transaction.Validator do
  @moduledoc """
  Pre-execution validation for an `EEVM.Context.Transaction` against current
  state and block.

  Checks (short-circuiting on the first failure): intrinsic gas floor, block
  gas limit, nonce, EIP-1559/4844 fee bounds, sender balance, sender is an
  EOA, EIP-4844 blob constraints, and EIP-3860 initcode size.
  """

  alias EEVM.Context.{Block, Transaction}
  alias EEVM.Database
  alias EEVM.HardforkConfig
  alias EEVM.Transaction.IntrinsicGas

  @blob_gas_per_blob 131_072
  @max_initcode_size 49_152

  @spec validate(Transaction.t(), Database.t(), Block.t()) :: :ok | {:error, atom()}
  def validate(%Transaction{} = tx, %Database{} = db, %Block{} = block) do
    validate(tx, db, block, HardforkConfig.default())
  end

  @spec validate(Transaction.t(), Database.t(), Block.t(), HardforkConfig.t()) ::
          :ok | {:error, atom()}
  def validate(
        %Transaction{} = tx,
        %Database{} = db,
        %Block{} = block,
        %HardforkConfig{} = hardfork
      ) do
    with :ok <- validate_intrinsic_gas(tx, hardfork),
         :ok <- validate_gas_limit_vs_block(tx, block),
         :ok <- validate_nonce(tx, db),
         :ok <- validate_eip1559_fees(tx, block),
         :ok <- validate_balance(tx, db),
         :ok <- validate_sender_is_eoa(tx, db),
         :ok <- validate_blob_tx(tx, block) do
      validate_initcode_size(tx)
    end
  end

  defp validate_intrinsic_gas(%Transaction{} = tx, %HardforkConfig{} = hardfork) do
    if tx.gas_limit >= IntrinsicGas.minimum_gas_limit(tx, hardfork),
      do: :ok,
      else: {:error, :intrinsic_gas_too_low}
  end

  defp validate_gas_limit_vs_block(%Transaction{} = tx, %Block{} = block) do
    if tx.gas_limit <= block.gaslimit,
      do: :ok,
      else: {:error, :gas_limit_exceeds_block}
  end

  defp validate_nonce(%Transaction{} = tx, %Database{} = db) do
    account_nonce = Database.get_nonce(db, tx.origin)

    cond do
      account_nonce == tx.nonce -> :ok
      account_nonce > tx.nonce -> {:error, :nonce_too_low}
      true -> {:error, :nonce_too_high}
    end
  end

  defp validate_eip1559_fees(%Transaction{type: type} = tx, %Block{} = block)
       when type in [:eip1559, :eip4844] do
    cond do
      tx.max_fee_per_gas < tx.max_priority_fee_per_gas ->
        {:error, :priority_fee_above_max_fee}

      tx.max_fee_per_gas < block.basefee ->
        {:error, :max_fee_below_basefee}

      true ->
        :ok
    end
  end

  defp validate_eip1559_fees(%Transaction{}, %Block{}), do: :ok

  defp validate_balance(%Transaction{} = tx, %Database{} = db) do
    sender_balance = Database.get_balance(db, tx.origin)
    required_balance = max_gas_cost(tx) + tx.value

    if sender_balance >= required_balance,
      do: :ok,
      else: {:error, :insufficient_balance}
  end

  defp validate_sender_is_eoa(%Transaction{} = tx, %Database{} = db) do
    if Database.get_code(db, tx.origin) == <<>>,
      do: :ok,
      else: {:error, :sender_not_eoa}
  end

  defp validate_blob_tx(%Transaction{type: :eip4844} = tx, %Block{} = block) do
    cond do
      tx.to == nil ->
        {:error, :blob_tx_no_creation}

      tx.blob_hashes == [] ->
        {:error, :no_blob_data}

      tx.max_fee_per_blob_gas < block.blob_base_fee ->
        {:error, :blob_fee_too_low}

      true ->
        :ok
    end
  end

  defp validate_blob_tx(%Transaction{}, %Block{}), do: :ok

  defp validate_initcode_size(%Transaction{to: nil, data: data}) do
    if byte_size(data) <= @max_initcode_size,
      do: :ok,
      else: {:error, :initcode_too_large}
  end

  defp validate_initcode_size(%Transaction{}), do: :ok

  defp max_gas_cost(%Transaction{type: type} = tx) when type in [:eip1559, :eip4844] do
    tx.gas_limit * tx.max_fee_per_gas + blob_gas_cost(tx)
  end

  defp max_gas_cost(%Transaction{} = tx) do
    tx.gas_limit * tx.gasprice
  end

  defp blob_gas_cost(%Transaction{type: :eip4844} = tx) do
    length(tx.blob_hashes) * @blob_gas_per_blob * tx.max_fee_per_blob_gas
  end

  defp blob_gas_cost(%Transaction{}), do: 0
end
