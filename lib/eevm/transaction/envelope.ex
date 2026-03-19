defmodule EEVM.Transaction.Envelope do
  @moduledoc """
  Transaction envelope encoding/decoding for legacy and typed transactions.
  """

  alias EEVM.Transaction
  alias EEVM.Transaction.{AccessList, Blob, FeeMarket, Legacy}

  @type_access_list 0x01
  @type_fee_market 0x02
  @type_blob 0x03

  @doc "Encode a transaction to its wire format (binary)."
  @spec encode(Transaction.t()) :: binary()
  def encode(%Legacy{} = tx) do
    [
      encode_integer(tx.nonce),
      encode_integer(tx.gas_price),
      encode_integer(tx.gas_limit),
      tx.to,
      encode_integer(tx.value),
      tx.data,
      encode_integer(tx.v),
      encode_integer(tx.r),
      encode_integer(tx.s)
    ]
    |> ExRLP.encode()
  end

  def encode(%AccessList{} = tx) do
    payload = [
      encode_integer(tx.chain_id),
      encode_integer(tx.nonce),
      encode_integer(tx.gas_price),
      encode_integer(tx.gas_limit),
      tx.to,
      encode_integer(tx.value),
      tx.data,
      encode_access_list(tx.access_list),
      encode_integer(tx.y_parity),
      encode_integer(tx.r),
      encode_integer(tx.s)
    ]

    <<@type_access_list>> <> ExRLP.encode(payload)
  end

  def encode(%FeeMarket{} = tx) do
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
      encode_integer(tx.y_parity),
      encode_integer(tx.r),
      encode_integer(tx.s)
    ]

    <<@type_fee_market>> <> ExRLP.encode(payload)
  end

  def encode(%Blob{} = tx) do
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
      tx.blob_versioned_hashes,
      encode_integer(tx.y_parity),
      encode_integer(tx.r),
      encode_integer(tx.s)
    ]

    <<@type_blob>> <> ExRLP.encode(payload)
  end

  @doc "Decode a transaction from wire format."
  @spec decode(binary()) :: {:ok, Transaction.t()} | {:error, atom()}
  def decode(<<>>), do: {:error, :empty_input}

  def decode(<<prefix, _::binary>> = encoded) when prefix >= 0xC0 do
    with {:ok, fields} <- decode_rlp(encoded) do
      decode_legacy(fields)
    end
  end

  def decode(<<@type_access_list, payload::binary>>) do
    with {:ok, fields} <- decode_rlp(payload) do
      decode_type_1(fields)
    end
  end

  def decode(<<@type_fee_market, payload::binary>>) do
    with {:ok, fields} <- decode_rlp(payload) do
      decode_type_2(fields)
    end
  end

  def decode(<<@type_blob, payload::binary>>) do
    with {:ok, fields} <- decode_rlp(payload) do
      decode_type_3(fields)
    end
  end

  def decode(<<_type, _::binary>>), do: {:error, :invalid_type}

  defp decode_rlp(binary) do
    {:ok, ExRLP.decode(binary)}
  rescue
    _ -> {:error, :invalid_rlp}
  end

  defp decode_legacy([
         nonce,
         gas_price,
         gas_limit,
         to,
         value,
         data,
         v,
         r,
         s
       ]) do
    with {:ok, nonce} <- decode_integer(nonce),
         {:ok, gas_price} <- decode_integer(gas_price),
         {:ok, gas_limit} <- decode_integer(gas_limit),
         :ok <- validate_address(to, allow_empty?: true),
         {:ok, value} <- decode_integer(value),
         true <- is_binary(data),
         {:ok, v} <- decode_integer(v),
         {:ok, r} <- decode_integer(r),
         {:ok, s} <- decode_integer(s) do
      {:ok,
       %Legacy{
         nonce: nonce,
         gas_price: gas_price,
         gas_limit: gas_limit,
         to: to,
         value: value,
         data: data,
         v: v,
         r: r,
         s: s
       }}
    else
      false -> {:error, :invalid_fields}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_legacy(_), do: {:error, :invalid_fields}

  defp decode_type_1([
         chain_id,
         nonce,
         gas_price,
         gas_limit,
         to,
         value,
         data,
         access_list,
         y_parity,
         r,
         s
       ]) do
    with {:ok, chain_id} <- decode_integer(chain_id),
         {:ok, nonce} <- decode_integer(nonce),
         {:ok, gas_price} <- decode_integer(gas_price),
         {:ok, gas_limit} <- decode_integer(gas_limit),
         :ok <- validate_address(to, allow_empty?: true),
         {:ok, value} <- decode_integer(value),
         true <- is_binary(data),
         {:ok, access_list} <- decode_access_list(access_list),
         {:ok, y_parity} <- decode_y_parity(y_parity),
         {:ok, r} <- decode_integer(r),
         {:ok, s} <- decode_integer(s) do
      {:ok,
       %AccessList{
         chain_id: chain_id,
         nonce: nonce,
         gas_price: gas_price,
         gas_limit: gas_limit,
         to: to,
         value: value,
         data: data,
         access_list: access_list,
         y_parity: y_parity,
         r: r,
         s: s
       }}
    else
      false -> {:error, :invalid_fields}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_type_1(_), do: {:error, :invalid_fields}

  defp decode_type_2([
         chain_id,
         nonce,
         max_priority_fee_per_gas,
         max_fee_per_gas,
         gas_limit,
         to,
         value,
         data,
         access_list,
         y_parity,
         r,
         s
       ]) do
    with {:ok, chain_id} <- decode_integer(chain_id),
         {:ok, nonce} <- decode_integer(nonce),
         {:ok, max_priority_fee_per_gas} <- decode_integer(max_priority_fee_per_gas),
         {:ok, max_fee_per_gas} <- decode_integer(max_fee_per_gas),
         {:ok, gas_limit} <- decode_integer(gas_limit),
         :ok <- validate_address(to, allow_empty?: true),
         {:ok, value} <- decode_integer(value),
         true <- is_binary(data),
         {:ok, access_list} <- decode_access_list(access_list),
         {:ok, y_parity} <- decode_y_parity(y_parity),
         {:ok, r} <- decode_integer(r),
         {:ok, s} <- decode_integer(s) do
      {:ok,
       %FeeMarket{
         chain_id: chain_id,
         nonce: nonce,
         max_priority_fee_per_gas: max_priority_fee_per_gas,
         max_fee_per_gas: max_fee_per_gas,
         gas_limit: gas_limit,
         to: to,
         value: value,
         data: data,
         access_list: access_list,
         y_parity: y_parity,
         r: r,
         s: s
       }}
    else
      false -> {:error, :invalid_fields}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_type_2(_), do: {:error, :invalid_fields}

  defp decode_type_3([
         chain_id,
         nonce,
         max_priority_fee_per_gas,
         max_fee_per_gas,
         gas_limit,
         to,
         value,
         data,
         access_list,
         max_fee_per_blob_gas,
         blob_versioned_hashes,
         y_parity,
         r,
         s
       ]) do
    with {:ok, chain_id} <- decode_integer(chain_id),
         {:ok, nonce} <- decode_integer(nonce),
         {:ok, max_priority_fee_per_gas} <- decode_integer(max_priority_fee_per_gas),
         {:ok, max_fee_per_gas} <- decode_integer(max_fee_per_gas),
         {:ok, gas_limit} <- decode_integer(gas_limit),
         :ok <- validate_address(to, allow_empty?: false),
         {:ok, value} <- decode_integer(value),
         true <- is_binary(data),
         {:ok, access_list} <- decode_access_list(access_list),
         {:ok, max_fee_per_blob_gas} <- decode_integer(max_fee_per_blob_gas),
         {:ok, blob_versioned_hashes} <- decode_blob_hashes(blob_versioned_hashes),
         {:ok, y_parity} <- decode_y_parity(y_parity),
         {:ok, r} <- decode_integer(r),
         {:ok, s} <- decode_integer(s) do
      {:ok,
       %Blob{
         chain_id: chain_id,
         nonce: nonce,
         max_priority_fee_per_gas: max_priority_fee_per_gas,
         max_fee_per_gas: max_fee_per_gas,
         gas_limit: gas_limit,
         to: to,
         value: value,
         data: data,
         access_list: access_list,
         max_fee_per_blob_gas: max_fee_per_blob_gas,
         blob_versioned_hashes: blob_versioned_hashes,
         y_parity: y_parity,
         r: r,
         s: s
       }}
    else
      false -> {:error, :invalid_fields}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_type_3(_), do: {:error, :invalid_fields}

  defp encode_access_list(access_list) do
    Enum.map(access_list, fn {address, slots} ->
      [address, slots]
    end)
  end

  defp decode_access_list(access_list) when is_list(access_list) do
    access_list
    |> Enum.reduce_while({:ok, []}, fn
      [address, slots], {:ok, acc} when is_binary(address) and is_list(slots) ->
        with :ok <- validate_address(address, allow_empty?: false),
             {:ok, decoded_slots} <- decode_slots(slots) do
          {:cont, {:ok, [{address, decoded_slots} | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_fields}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp decode_access_list(_), do: {:error, :invalid_fields}

  defp decode_slots(slots) do
    slots
    |> Enum.reduce_while({:ok, []}, fn
      slot, {:ok, acc} when is_binary(slot) and byte_size(slot) == 32 ->
        {:cont, {:ok, [slot | acc]}}

      _slot, _acc ->
        {:halt, {:error, :invalid_fields}}
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_blob_hashes(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      hash, {:ok, acc} when is_binary(hash) and byte_size(hash) == 32 ->
        {:cont, {:ok, [hash | acc]}}

      _hash, _acc ->
        {:halt, {:error, :invalid_fields}}
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_blob_hashes(_), do: {:error, :invalid_fields}

  defp validate_address(address, opts) do
    allow_empty? = Keyword.fetch!(opts, :allow_empty?)

    cond do
      is_binary(address) and byte_size(address) == 20 -> :ok
      allow_empty? and address == <<>> -> :ok
      true -> {:error, :invalid_fields}
    end
  end

  defp decode_y_parity(value) do
    with {:ok, y_parity} <- decode_integer(value),
         true <- y_parity in [0, 1] do
      {:ok, y_parity}
    else
      false -> {:error, :invalid_fields}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_integer(value) when is_binary(value) do
    cond do
      value == <<>> -> {:ok, 0}
      :binary.first(value) == 0 -> {:error, :invalid_rlp_integer}
      true -> {:ok, :binary.decode_unsigned(value)}
    end
  end

  defp decode_integer(_), do: {:error, :invalid_fields}

  defp encode_integer(0), do: <<>>

  defp encode_integer(value) when is_integer(value) and value > 0,
    do: :binary.encode_unsigned(value)
end
