defmodule EEVM.Handler.Validation do
  @moduledoc """
  Pre-flight checks on a wire transaction.

  This phase handles steps 1-3 of the transaction pipeline (Yellow Paper §6):

  1. **Decode** the wire bytes (or accept an already-decoded typed struct).
  2. **Recover sender** via secp256k1 ecrecover on the typed signing hash.
  3. **Validate** intrinsic gas, nonce, balance, EOA sender, EIP-1559 fee
     constraints, blob/initcode size rules.

  Outputs `{:ok, %EEVM.TxEnv{}}` ready for the next phase, or
  `{:error, reason}` for any failure.
  """

  alias EEVM.{BlockEnv, Config, Database, HardforkConfig, Tracer, TxEnv}

  alias EEVM.Transaction.{
    AccessList,
    Authorization,
    Blob,
    Envelope,
    FeeMarket,
    Legacy,
    SetCode,
    Signer,
    Validator
  }

  @type decoded_tx :: Legacy.t() | AccessList.t() | FeeMarket.t() | Blob.t() | SetCode.t()
  @type wire_tx :: decoded_tx() | binary()

  @default_hardfork :cancun

  @doc """
  Use `opts[:config]` if given, else build one from `opts[:hardfork]` (default
  `:cancun`). The deprecated `:chain_id` option, when given, overrides the
  config's chain id.
  """
  @spec resolve_config(keyword()) :: Config.t()
  def resolve_config(opts) do
    config =
      case Keyword.fetch(opts, :config) do
        {:ok, %Config{} = config} -> config
        _ -> Config.new(Keyword.get(opts, :hardfork, @default_hardfork))
      end

    case Keyword.fetch(opts, :chain_id) do
      {:ok, chain_id} -> %{config | chain_id: chain_id}
      :error -> config
    end
  end

  @doc """
  The `EEVM.Tracer` that `opts[:tracer]` asks for: a new one for `true`, the
  given one, or `nil` (no tracing) when absent or `false`.
  """
  @spec resolve_tracer(keyword()) :: Tracer.t() | nil
  def resolve_tracer(opts) do
    case Keyword.get(opts, :tracer) do
      true -> Tracer.new()
      %Tracer{} = tracer -> tracer
      off when off in [nil, false] -> nil
    end
  end

  @doc "Decode wire bytes into a typed transaction struct, or pass a struct through."
  @spec ensure_decoded(wire_tx()) :: {:ok, decoded_tx()} | {:error, atom()}
  def ensure_decoded(%Legacy{} = tx), do: {:ok, tx}
  def ensure_decoded(%AccessList{} = tx), do: {:ok, tx}
  def ensure_decoded(%FeeMarket{} = tx), do: {:ok, tx}
  def ensure_decoded(%Blob{} = tx), do: {:ok, tx}
  def ensure_decoded(%SetCode{} = tx), do: {:ok, tx}
  def ensure_decoded(bytes) when is_binary(bytes), do: Envelope.decode(bytes)
  def ensure_decoded(_), do: {:error, :invalid_transaction_input}

  @doc "Recover the sender address; see `EEVM.Transaction.Signer.recover_sender/2`."
  @spec recover_sender(decoded_tx(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  defdelegate recover_sender(tx, chain_id), to: Signer

  @doc "Validate the transaction against state; see `EEVM.Transaction.Validator.validate/4`."
  @spec validate(TxEnv.t(), Database.t(), BlockEnv.t(), HardforkConfig.t()) ::
          :ok | {:error, atom()}
  defdelegate validate(tx_ctx, db, block, hardfork), to: Validator

  @doc "Build the `EEVM.TxEnv` the EVM sees from a decoded transaction."
  @spec build_tx_context(decoded_tx(), non_neg_integer()) :: {:ok, TxEnv.t()}
  def build_tx_context(%Legacy{} = tx, sender) do
    {:ok,
     TxEnv.new(
       origin: sender,
       nonce: tx.nonce,
       gas_limit: tx.gas_limit,
       to: optional_address(tx.to),
       value: tx.value,
       data: tx.data,
       gas_price: tx.gas_price,
       max_fee_per_gas: tx.gas_price,
       max_priority_fee_per_gas: tx.gas_price,
       access_list: [],
       blob_hashes: [],
       max_fee_per_blob_gas: 0,
       type: :legacy
     )}
  end

  def build_tx_context(%AccessList{} = tx, sender) do
    {:ok,
     TxEnv.new(
       origin: sender,
       nonce: tx.nonce,
       gas_limit: tx.gas_limit,
       to: optional_address(tx.to),
       value: tx.value,
       data: tx.data,
       gas_price: tx.gas_price,
       max_fee_per_gas: tx.gas_price,
       max_priority_fee_per_gas: tx.gas_price,
       access_list: decode_access_list(tx.access_list),
       blob_hashes: [],
       max_fee_per_blob_gas: 0,
       type: :eip2930
     )}
  end

  def build_tx_context(%FeeMarket{} = tx, sender) do
    {:ok,
     TxEnv.new(
       origin: sender,
       nonce: tx.nonce,
       gas_limit: tx.gas_limit,
       to: optional_address(tx.to),
       value: tx.value,
       data: tx.data,
       gas_price: 0,
       max_fee_per_gas: tx.max_fee_per_gas,
       max_priority_fee_per_gas: tx.max_priority_fee_per_gas,
       access_list: decode_access_list(tx.access_list),
       blob_hashes: [],
       max_fee_per_blob_gas: 0,
       type: :eip1559
     )}
  end

  def build_tx_context(%Blob{} = tx, sender) do
    {:ok,
     TxEnv.new(
       origin: sender,
       nonce: tx.nonce,
       gas_limit: tx.gas_limit,
       to: optional_address(tx.to),
       value: tx.value,
       data: tx.data,
       gas_price: 0,
       max_fee_per_gas: tx.max_fee_per_gas,
       max_priority_fee_per_gas: tx.max_priority_fee_per_gas,
       access_list: decode_access_list(tx.access_list),
       blob_hashes: Enum.map(tx.blob_versioned_hashes, &:binary.decode_unsigned/1),
       max_fee_per_blob_gas: tx.max_fee_per_blob_gas,
       type: :eip4844
     )}
  end

  def build_tx_context(%SetCode{} = tx, sender) do
    {:ok,
     TxEnv.new(
       origin: sender,
       nonce: tx.nonce,
       gas_limit: tx.gas_limit,
       to: optional_address(tx.to),
       value: tx.value,
       data: tx.data,
       gas_price: 0,
       max_fee_per_gas: tx.max_fee_per_gas,
       max_priority_fee_per_gas: tx.max_priority_fee_per_gas,
       access_list: decode_access_list(tx.access_list),
       authorization_list: Enum.map(tx.authorization_list, &decode_authorization/1),
       blob_hashes: [],
       max_fee_per_blob_gas: 0,
       type: :eip7702
     )}
  end

  # Transaction structs hold integer addresses and storage keys; the
  # deprecated binary forms are converted here.
  defp optional_address(nil), do: nil
  defp optional_address(<<>>), do: nil
  defp optional_address(address), do: EEVM.address(address)

  defp decode_authorization(%Authorization{} = auth) do
    auth
    |> Map.from_struct()
    |> Map.update!(:address, &EEVM.address/1)
  end

  defp decode_access_list(access_list) do
    Enum.map(access_list, fn {address, keys} ->
      {EEVM.address(address), Enum.map(keys, &storage_key/1)}
    end)
  end

  defp storage_key(<<key::unsigned-big-256>>), do: key
  defp storage_key(key) when is_integer(key), do: key
end
