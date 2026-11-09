defmodule EEVM.Transaction.Validator do
  @moduledoc """
  Transaction pre-execution validation.

  Performs envelope and sender checks in deterministic order against current
  state and block context, returning `:ok` or the first `{:error, reason}`.
  """

  alias EEVM.Context.{Block, Transaction}
  alias EEVM.{Database, Delegation}
  alias EEVM.Error
  alias EEVM.HardforkConfig
  alias EEVM.Transaction.IntrinsicGas

  @blob_gas_per_blob 131_072
  @max_initcode_size 49_152
  # EIP-7825: per-transaction gas limit cap (2^24), independent of the block gas limit.
  @max_tx_gas_limit 16_777_216
  @max_uint8 0xFF
  @max_uint64 0xFFFFFFFFFFFFFFFF
  @max_uint256 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

  @doc "Validate under the default hardfork; see `validate/4`."
  @spec validate(Transaction.t(), Database.t(), Block.t()) ::
          :ok | {:error, Error.transaction_validation_error()}
  def validate(%Transaction{} = tx, %Database{} = db, %Block{} = block) do
    validate(tx, db, block, HardforkConfig.default())
  end

  @doc """
  Run the pre-execution checks in order and return the first failure.
  Error reasons are listed in `EEVM.Error`.
  """
  @spec validate(Transaction.t(), Database.t(), Block.t(), HardforkConfig.t()) ::
          :ok | {:error, Error.transaction_validation_error()}
  def validate(
        %Transaction{} = tx,
        %Database{} = db,
        %Block{} = block,
        %HardforkConfig{} = hardfork
      ) do
    with :ok <- validate_tx_type(tx, hardfork),
         :ok <- validate_set_code_tx(tx),
         :ok <- validate_intrinsic_gas(tx, hardfork),
         :ok <- validate_gas_limit_cap(tx, hardfork),
         :ok <- validate_gas_limit_vs_block(tx, block),
         :ok <- validate_nonce(tx, db),
         :ok <- validate_eip1559_fees(tx, block),
         :ok <- validate_balance(tx, db),
         :ok <- validate_sender_is_eoa(tx, db),
         :ok <- validate_blob_tx(tx, block) do
      validate_initcode_size(tx)
    end
  end

  defp validate_tx_type(%Transaction{type: :eip7702}, %HardforkConfig{} = hardfork) do
    if HardforkConfig.enabled?(hardfork, :eip_7702),
      do: :ok,
      else: {:error, :tx_type_not_supported}
  end

  defp validate_tx_type(%Transaction{}, %HardforkConfig{}), do: :ok

  defp validate_set_code_tx(%Transaction{type: :eip7702} = tx) do
    cond do
      tx.to == nil -> {:error, :set_code_tx_no_creation}
      tx.authorization_list == [] -> {:error, :empty_authorization_list}
      Enum.all?(tx.authorization_list, &authorization_in_range?/1) -> :ok
      true -> {:error, :invalid_authorization}
    end
  end

  defp validate_set_code_tx(%Transaction{}), do: :ok

  # Field widths from the EIP-7702 RLP schema; a value that does not fit
  # makes the whole transaction undecodable rather than skipping the tuple.
  defp authorization_in_range?(auth) do
    auth.chain_id <= @max_uint256 and auth.nonce <= @max_uint64 and
      auth.y_parity <= @max_uint8 and auth.r <= @max_uint256 and auth.s <= @max_uint256
  end

  defp validate_intrinsic_gas(%Transaction{} = tx, %HardforkConfig{} = hardfork) do
    if tx.gas_limit >= IntrinsicGas.minimum_gas_limit(tx, hardfork),
      do: :ok,
      else: {:error, :intrinsic_gas_too_low}
  end

  defp validate_gas_limit_cap(%Transaction{} = tx, %HardforkConfig{} = hardfork) do
    if tx.gas_limit > @max_tx_gas_limit and HardforkConfig.enabled?(hardfork, :eip_7825),
      do: {:error, :gas_limit_exceeds_cap},
      else: :ok
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
       when type in [:eip1559, :eip4844, :eip7702] do
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

  # EIP-3607, relaxed by EIP-7702: an EOA that delegated its code may still send.
  defp validate_sender_is_eoa(%Transaction{} = tx, %Database{} = db) do
    code = Database.get_code(db, tx.origin)

    if code == <<>> or Delegation.designator?(code),
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

  defp max_gas_cost(%Transaction{type: type} = tx) when type in [:eip1559, :eip4844, :eip7702] do
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
