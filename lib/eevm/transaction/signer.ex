defmodule EEVM.Transaction.Signer do
  @moduledoc """
  Transaction signing-hash computation and sender recovery.
  """

  alias EEVM.Transaction
  alias EEVM.Transaction.{AccessList, Blob, FeeMarket, Legacy}

  @secp256k1n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @secp256k1n_half div(@secp256k1n, 2)

  @doc "Compute the signing hash for a transaction."
  @spec signing_hash(Transaction.t(), non_neg_integer()) :: binary()
  def signing_hash(%Legacy{v: v} = tx, _chain_id) when v in [27, 28] do
    [
      encode_integer(tx.nonce),
      encode_integer(tx.gas_price),
      encode_integer(tx.gas_limit),
      tx.to,
      encode_integer(tx.value),
      tx.data
    ]
    |> ExRLP.encode()
    |> ExKeccak.hash_256()
  end

  def signing_hash(%Legacy{} = tx, chain_id) do
    [
      encode_integer(tx.nonce),
      encode_integer(tx.gas_price),
      encode_integer(tx.gas_limit),
      tx.to,
      encode_integer(tx.value),
      tx.data,
      encode_integer(chain_id),
      <<>>,
      <<>>
    ]
    |> ExRLP.encode()
    |> ExKeccak.hash_256()
  end

  def signing_hash(%AccessList{} = tx, _chain_id) do
    payload = [
      encode_integer(tx.chain_id),
      encode_integer(tx.nonce),
      encode_integer(tx.gas_price),
      encode_integer(tx.gas_limit),
      tx.to,
      encode_integer(tx.value),
      tx.data,
      encode_access_list(tx.access_list)
    ]

    ExKeccak.hash_256(<<0x01>> <> ExRLP.encode(payload))
  end

  def signing_hash(%FeeMarket{} = tx, _chain_id) do
    payload = [
      encode_integer(tx.chain_id),
      encode_integer(tx.nonce),
      encode_integer(tx.max_priority_fee_per_gas),
      encode_integer(tx.max_fee_per_gas),
      encode_integer(tx.gas_limit),
      tx.to,
      encode_integer(tx.value),
      tx.data,
      encode_access_list(tx.access_list)
    ]

    ExKeccak.hash_256(<<0x02>> <> ExRLP.encode(payload))
  end

  def signing_hash(%Blob{} = tx, _chain_id) do
    payload = [
      encode_integer(tx.chain_id),
      encode_integer(tx.nonce),
      encode_integer(tx.max_priority_fee_per_gas),
      encode_integer(tx.max_fee_per_gas),
      encode_integer(tx.gas_limit),
      tx.to,
      encode_integer(tx.value),
      tx.data,
      encode_access_list(tx.access_list),
      encode_integer(tx.max_fee_per_blob_gas),
      tx.blob_versioned_hashes
    ]

    ExKeccak.hash_256(<<0x03>> <> ExRLP.encode(payload))
  end

  @doc "Recover the sender address from a signed transaction."
  @spec recover_sender(Transaction.t(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def recover_sender(tx, chain_id) do
    with {:ok, y_parity, r, s} <- extract_signature(tx, chain_id),
         :ok <- validate_signature_scalars(r, s),
         hash <- signing_hash(tx, chain_id),
         signature = <<r::unsigned-big-256, s::unsigned-big-256>>,
         {:ok, public_key} <- ExSecp256k1.recover_compact(hash, signature, y_parity),
         {:ok, address} <- public_key_to_address(public_key) do
      {:ok, address}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_signature(%Legacy{} = tx, chain_id) do
    with {:ok, y_parity} <- legacy_y_parity(tx.v, chain_id) do
      {:ok, y_parity, tx.r, tx.s}
    end
  end

  defp extract_signature(%AccessList{} = tx, _chain_id), do: {:ok, tx.y_parity, tx.r, tx.s}
  defp extract_signature(%FeeMarket{} = tx, _chain_id), do: {:ok, tx.y_parity, tx.r, tx.s}
  defp extract_signature(%Blob{} = tx, _chain_id), do: {:ok, tx.y_parity, tx.r, tx.s}

  defp legacy_y_parity(v, _chain_id) when v in [27, 28], do: {:ok, v - 27}

  defp legacy_y_parity(v, chain_id)
       when is_integer(v) and is_integer(chain_id) and chain_id >= 0 do
    y_parity = v - 35 - 2 * chain_id

    if y_parity in [0, 1] do
      {:ok, y_parity}
    else
      {:error, :invalid_v}
    end
  end

  defp legacy_y_parity(_, _), do: {:error, :invalid_v}

  defp validate_signature_scalars(r, s)
       when is_integer(r) and is_integer(s) and r > 0 and r < @secp256k1n and s > 0 and
              s <= @secp256k1n_half,
       do: :ok

  defp validate_signature_scalars(_, _), do: {:error, :invalid_signature}

  defp public_key_to_address(<<4, key::binary-size(64)>>) do
    <<_::binary-size(12), address::binary-size(20)>> = ExKeccak.hash_256(key)
    {:ok, address}
  end

  defp public_key_to_address(key) when is_binary(key) and byte_size(key) == 64 do
    <<_::binary-size(12), address::binary-size(20)>> = ExKeccak.hash_256(key)
    {:ok, address}
  end

  defp public_key_to_address(_), do: {:error, :invalid_signature}

  defp encode_access_list(access_list) do
    Enum.map(access_list, fn {address, slots} ->
      [address, slots]
    end)
  end

  defp encode_integer(0), do: <<>>

  defp encode_integer(value) when is_integer(value) and value > 0,
    do: :binary.encode_unsigned(value)
end
