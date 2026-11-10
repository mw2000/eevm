defmodule EEVM.Transaction.Validator do
  @moduledoc """
  Transaction pre-execution validation.

  Performs envelope and sender checks in deterministic order against current
  state and block context, returning `:ok` or the first `{:error, reason}`.
  """

  alias EEVM.{BlockEnv, Database, Delegation, TxEnv}
  alias EEVM.Error
  alias EEVM.Gas.Blob
  alias EEVM.HardforkConfig
  alias EEVM.Transaction.IntrinsicGas

  import Bitwise

  @blob_gas_per_blob 131_072
  @max_initcode_size 49_152
  # EIP-7825: per-transaction gas limit cap (2^24), independent of the block gas limit.
  @max_tx_gas_limit 16_777_216
  @max_uint8 0xFF
  @max_uint64 0xFFFFFFFFFFFFFFFF
  @max_uint256 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
  # EIP-4844: a blob versioned hash starts with VERSIONED_HASH_VERSION_KZG.
  @versioned_hash_version_kzg 0x01
  # EIP-7594: at most this many blobs per transaction.
  @max_blobs_per_tx 6

  @doc "Validate under the default hardfork; see `validate/4`."
  @spec validate(TxEnv.t(), Database.t(), BlockEnv.t()) ::
          :ok | {:error, Error.transaction_validation_error()}
  def validate(%TxEnv{} = tx, %Database{} = db, %BlockEnv{} = block) do
    validate(tx, db, block, HardforkConfig.default())
  end

  @doc """
  Run the pre-execution checks in order and return the first failure.
  Error reasons are listed in `EEVM.Error`.
  """
  @spec validate(TxEnv.t(), Database.t(), BlockEnv.t(), HardforkConfig.t()) ::
          :ok | {:error, Error.transaction_validation_error()}
  def validate(
        %TxEnv{} = tx,
        %Database{} = db,
        %BlockEnv{} = block,
        %HardforkConfig{} = hardfork
      ) do
    with :ok <- validate_tx_type(tx, hardfork),
         :ok <- validate_set_code_tx(tx),
         :ok <- validate_intrinsic_gas(tx, hardfork),
         :ok <- validate_gas_limit_cap(tx, hardfork),
         :ok <- validate_gas_limit_vs_block(tx, block),
         :ok <- validate_nonce(tx, db),
         :ok <- validate_eip1559_fees(tx, block, hardfork),
         :ok <- validate_balance(tx, db),
         :ok <- validate_sender_is_eoa(tx, db),
         :ok <- validate_blob_tx(tx, block, hardfork) do
      validate_initcode_size(tx)
    end
  end

  # Each EIP-2718 transaction type is valid from the fork of the EIP that
  # introduced it.
  @tx_type_eips %{eip2930: :eip_2930, eip1559: :eip_1559, eip4844: :eip_4844, eip7702: :eip_7702}

  defp validate_tx_type(%TxEnv{type: type}, %HardforkConfig{} = hardfork) do
    case @tx_type_eips do
      %{^type => eip} ->
        if HardforkConfig.enabled?(hardfork, eip), do: :ok, else: {:error, :tx_type_not_supported}

      _legacy ->
        :ok
    end
  end

  defp validate_set_code_tx(%TxEnv{type: :eip7702} = tx) do
    cond do
      tx.to == nil -> {:error, :set_code_tx_no_creation}
      tx.authorization_list == [] -> {:error, :empty_authorization_list}
      Enum.all?(tx.authorization_list, &authorization_in_range?/1) -> :ok
      true -> {:error, :invalid_authorization}
    end
  end

  defp validate_set_code_tx(%TxEnv{}), do: :ok

  # Field widths from the EIP-7702 RLP schema; a value that does not fit
  # makes the whole transaction undecodable rather than skipping the tuple.
  defp authorization_in_range?(auth) do
    auth.chain_id <= @max_uint256 and auth.nonce <= @max_uint64 and
      auth.y_parity <= @max_uint8 and auth.r <= @max_uint256 and auth.s <= @max_uint256
  end

  defp validate_intrinsic_gas(%TxEnv{} = tx, %HardforkConfig{} = hardfork) do
    if tx.gas_limit >= IntrinsicGas.minimum_gas_limit(tx, hardfork),
      do: :ok,
      else: {:error, :intrinsic_gas_too_low}
  end

  defp validate_gas_limit_cap(%TxEnv{} = tx, %HardforkConfig{} = hardfork) do
    if tx.gas_limit > @max_tx_gas_limit and HardforkConfig.enabled?(hardfork, :eip_7825),
      do: {:error, :gas_limit_exceeds_cap},
      else: :ok
  end

  defp validate_gas_limit_vs_block(%TxEnv{} = tx, %BlockEnv{} = block) do
    if tx.gas_limit <= block.gas_limit,
      do: :ok,
      else: {:error, :gas_limit_exceeds_block}
  end

  defp validate_nonce(%TxEnv{} = tx, %Database{} = db) do
    account_nonce = Database.get_nonce(db, tx.origin)

    cond do
      account_nonce > tx.nonce -> {:error, :nonce_too_low}
      account_nonce < tx.nonce -> {:error, :nonce_too_high}
      # EIP-2681: the sender's nonce could not be incremented.
      tx.nonce >= @max_uint64 -> {:error, :nonce_is_max}
      true -> :ok
    end
  end

  defp validate_eip1559_fees(%TxEnv{type: type} = tx, %BlockEnv{} = block, _hardfork)
       when type in [:eip1559, :eip4844, :eip7702] do
    cond do
      tx.max_fee_per_gas < tx.max_priority_fee_per_gas ->
        {:error, :priority_fee_above_max_fee}

      tx.max_fee_per_gas < block.base_fee ->
        {:error, :max_fee_below_basefee}

      true ->
        :ok
    end
  end

  # From London, a legacy or EIP-2930 transaction's gas price must cover the
  # base fee too (execution-specs London `check_transaction`).
  defp validate_eip1559_fees(%TxEnv{} = tx, %BlockEnv{} = block, %HardforkConfig{} = hardfork) do
    if HardforkConfig.enabled?(hardfork, :eip_1559) and tx.gas_price < block.base_fee,
      do: {:error, :max_fee_below_basefee},
      else: :ok
  end

  defp validate_balance(%TxEnv{} = tx, %Database{} = db) do
    sender_balance = Database.get_balance(db, tx.origin)
    required_balance = max_gas_cost(tx) + tx.value

    if sender_balance >= required_balance,
      do: :ok,
      else: {:error, :insufficient_balance}
  end

  # EIP-3607, relaxed by EIP-7702: an EOA that delegated its code may still send.
  defp validate_sender_is_eoa(%TxEnv{} = tx, %Database{} = db) do
    code = Database.get_code(db, tx.origin)

    if code == <<>> or Delegation.designator?(code),
      do: :ok,
      else: {:error, :sender_not_eoa}
  end

  # EIP-4844 and EIP-7594 rules from execution-specs `check_transaction`.
  defp validate_blob_tx(%TxEnv{type: :eip4844} = tx, %BlockEnv{} = block, hardfork) do
    blob_count = length(tx.blob_hashes)

    cond do
      tx.to == nil ->
        {:error, :blob_tx_no_creation}

      blob_count == 0 ->
        {:error, :no_blob_data}

      blob_count * @blob_gas_per_blob > Blob.max_blob_gas_per_block(hardfork) ->
        {:error, :too_many_blobs}

      HardforkConfig.enabled?(hardfork, :eip_7594) and blob_count > @max_blobs_per_tx ->
        {:error, :too_many_blobs}

      not Enum.all?(tx.blob_hashes, &(&1 >>> 248 == @versioned_hash_version_kzg)) ->
        {:error, :invalid_versioned_hash}

      tx.max_fee_per_blob_gas < block.blob_base_fee ->
        {:error, :blob_fee_too_low}

      true ->
        :ok
    end
  end

  defp validate_blob_tx(%TxEnv{}, %BlockEnv{}, _hardfork), do: :ok

  defp validate_initcode_size(%TxEnv{to: nil, data: data}) do
    if byte_size(data) <= @max_initcode_size,
      do: :ok,
      else: {:error, :initcode_too_large}
  end

  defp validate_initcode_size(%TxEnv{}), do: :ok

  defp max_gas_cost(%TxEnv{type: type} = tx) when type in [:eip1559, :eip4844, :eip7702] do
    tx.gas_limit * tx.max_fee_per_gas + blob_gas_cost(tx)
  end

  defp max_gas_cost(%TxEnv{} = tx) do
    tx.gas_limit * tx.gas_price
  end

  defp blob_gas_cost(%TxEnv{type: :eip4844} = tx) do
    length(tx.blob_hashes) * @blob_gas_per_blob * tx.max_fee_per_blob_gas
  end

  defp blob_gas_cost(%TxEnv{}), do: 0
end
