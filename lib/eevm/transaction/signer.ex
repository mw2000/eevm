defmodule EEVM.Transaction.Signer do
  @moduledoc """
  Transaction signing, signing hashes, and sender recovery.

  ## Example

      iex> alias EEVM.Transaction.{FeeMarket, Signer}
      iex> tx = %FeeMarket{max_priority_fee_per_gas: 1, max_fee_per_gas: 10, gas_limit: 21_000, to: 0xB0B}
      iex> private_key = :binary.copy(<<0x46>>, 32)
      iex> {:ok, signed} = Signer.sign(tx, private_key, EEVM.Config.new(:cancun, chain_id: 5))
      iex> signed.chain_id
      5
      iex> {:ok, sender} = Signer.recover_sender(signed, 5)
      iex> EEVM.hex(<<sender::160>>)
      "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f"
  """

  alias EEVM.{Config, Transaction}
  alias EEVM.Crypto.{ECDSA, Keccak}
  alias EEVM.Transaction.{AccessList, Authorization, Blob, FeeMarket, Legacy, SetCode}

  @secp256k1n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @secp256k1n_half div(@secp256k1n, 2)

  @doc """
  Signs `tx` with the 32-byte secp256k1 `private_key` for `config`'s chain.

  A legacy transaction is signed with EIP-155 replay protection, so its `v`
  becomes `chain_id * 2 + 35 + y_parity`. A typed transaction whose
  `chain_id` is `nil` takes the config's; one that already has a `chain_id`
  keeps it. Any existing signature is replaced. Signatures are low-`s`
  (EIP-2).

  Returns `{:ok, signed_tx}`, or `{:error, :invalid_private_key}` when the
  key is zero or not below the curve order.
  """
  @spec sign(Transaction.t(), <<_::256>>, Config.t()) ::
          {:ok, Transaction.t()} | {:error, :invalid_private_key}
  def sign(tx, <<_::256>> = private_key, %Config{chain_id: chain_id}) do
    tx = put_chain_id(tx, chain_id)

    with {:ok, {r, s, y_parity}} <-
           ECDSA.sign(:secp256k1, signing_hash(unsigned(tx), chain_id), private_key) do
      {:ok, put_signature(tx, chain_id, y_parity, r, s)}
    end
  end

  defp put_chain_id(%Legacy{} = tx, _chain_id), do: tx
  defp put_chain_id(%{chain_id: nil} = tx, chain_id), do: %{tx | chain_id: chain_id}
  defp put_chain_id(tx, _chain_id), do: tx

  # A legacy `v` of 27 or 28 would select the pre-EIP-155 signing hash.
  defp unsigned(%Legacy{} = tx), do: %{tx | v: nil}
  defp unsigned(tx), do: tx

  defp put_signature(%Legacy{} = tx, chain_id, y_parity, r, s),
    do: %{tx | v: chain_id * 2 + 35 + y_parity, r: r, s: s}

  defp put_signature(tx, _chain_id, y_parity, r, s), do: %{tx | y_parity: y_parity, r: r, s: s}

  @doc "Compute the signing hash for a transaction."
  @spec signing_hash(Transaction.t(), non_neg_integer()) :: binary()
  def signing_hash(%Legacy{v: v} = tx, _chain_id) when v in [27, 28] do
    [
      encode_integer(tx.nonce),
      encode_integer(tx.gas_price),
      encode_integer(tx.gas_limit),
      Transaction.address_bytes(tx.to),
      encode_integer(tx.value),
      tx.data
    ]
    |> ExRLP.encode()
    |> Keccak.hash_256()
  end

  def signing_hash(%Legacy{} = tx, chain_id) do
    [
      encode_integer(tx.nonce),
      encode_integer(tx.gas_price),
      encode_integer(tx.gas_limit),
      Transaction.address_bytes(tx.to),
      encode_integer(tx.value),
      tx.data,
      encode_integer(chain_id),
      <<>>,
      <<>>
    ]
    |> ExRLP.encode()
    |> Keccak.hash_256()
  end

  def signing_hash(%AccessList{} = tx, _chain_id) do
    payload = [
      encode_integer(tx.chain_id),
      encode_integer(tx.nonce),
      encode_integer(tx.gas_price),
      encode_integer(tx.gas_limit),
      Transaction.address_bytes(tx.to),
      encode_integer(tx.value),
      tx.data,
      Transaction.access_list_rlp(tx.access_list)
    ]

    Keccak.hash_256(<<0x01>> <> ExRLP.encode(payload))
  end

  def signing_hash(%FeeMarket{} = tx, _chain_id) do
    payload = [
      encode_integer(tx.chain_id),
      encode_integer(tx.nonce),
      encode_integer(tx.max_priority_fee_per_gas),
      encode_integer(tx.max_fee_per_gas),
      encode_integer(tx.gas_limit),
      Transaction.address_bytes(tx.to),
      encode_integer(tx.value),
      tx.data,
      Transaction.access_list_rlp(tx.access_list)
    ]

    Keccak.hash_256(<<0x02>> <> ExRLP.encode(payload))
  end

  def signing_hash(%Blob{} = tx, _chain_id) do
    payload = [
      encode_integer(tx.chain_id),
      encode_integer(tx.nonce),
      encode_integer(tx.max_priority_fee_per_gas),
      encode_integer(tx.max_fee_per_gas),
      encode_integer(tx.gas_limit),
      Transaction.address_bytes(tx.to),
      encode_integer(tx.value),
      tx.data,
      Transaction.access_list_rlp(tx.access_list),
      encode_integer(tx.max_fee_per_blob_gas),
      tx.blob_versioned_hashes
    ]

    Keccak.hash_256(<<0x03>> <> ExRLP.encode(payload))
  end

  def signing_hash(%SetCode{} = tx, _chain_id) do
    payload = [
      encode_integer(tx.chain_id),
      encode_integer(tx.nonce),
      encode_integer(tx.max_priority_fee_per_gas),
      encode_integer(tx.max_fee_per_gas),
      encode_integer(tx.gas_limit),
      Transaction.address_bytes(tx.to),
      encode_integer(tx.value),
      tx.data,
      Transaction.access_list_rlp(tx.access_list),
      Enum.map(tx.authorization_list, &authorization_fields/1)
    ]

    Keccak.hash_256(<<0x04>> <> ExRLP.encode(payload))
  end

  @doc "Recover the sender address, as an integer, from a signed transaction."
  @spec recover_sender(Transaction.t(), non_neg_integer()) ::
          {:ok, Transaction.address()} | {:error, atom()}
  def recover_sender(tx, chain_id) do
    with {:ok, y_parity, r, s} <- extract_signature(tx, chain_id) do
      recover(signing_hash(tx, chain_id), y_parity, r, s)
    end
  end

  @doc """
  Recover the authority (signer) of an EIP-7702 authorization tuple.

  The signed message is `keccak256(0x05 || rlp([chain_id, address, nonce]))`.
  Signatures with `y_parity` outside `0..1`, `r` outside `1..n-1`, or a
  high `s` (EIP-2) are rejected with `{:error, :invalid_signature}`.
  """
  @spec recover_authority(Authorization.t()) :: {:ok, Transaction.address()} | {:error, atom()}
  def recover_authority(%Authorization{y_parity: y_parity} = auth) when y_parity in [0, 1] do
    message =
      ExRLP.encode([
        encode_integer(auth.chain_id),
        Transaction.address_bytes(auth.address),
        encode_integer(auth.nonce)
      ])

    recover(Keccak.hash_256(<<0x05>> <> message), y_parity, auth.r, auth.s)
  end

  def recover_authority(%Authorization{}), do: {:error, :invalid_signature}

  defp recover(hash, y_parity, r, s) when y_parity in [0, 1] do
    with :ok <- validate_signature_scalars(r, s),
         {:ok, {x, y}} <- ECDSA.recover(:secp256k1, hash, r, s, y_parity) do
      <<_::binary-size(12), address::unsigned-big-160>> = Keccak.hash_256(<<x::256, y::256>>)
      {:ok, address}
    end
  end

  defp recover(_hash, _y_parity, _r, _s), do: {:error, :invalid_signature}

  defp extract_signature(%Legacy{} = tx, chain_id) do
    with {:ok, y_parity} <- legacy_y_parity(tx.v, chain_id) do
      {:ok, y_parity, tx.r, tx.s}
    end
  end

  defp extract_signature(%AccessList{} = tx, _chain_id), do: {:ok, tx.y_parity, tx.r, tx.s}
  defp extract_signature(%FeeMarket{} = tx, _chain_id), do: {:ok, tx.y_parity, tx.r, tx.s}
  defp extract_signature(%Blob{} = tx, _chain_id), do: {:ok, tx.y_parity, tx.r, tx.s}
  defp extract_signature(%SetCode{} = tx, _chain_id), do: {:ok, tx.y_parity, tx.r, tx.s}

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

  defp authorization_fields(%Authorization{} = auth) do
    [
      encode_integer(auth.chain_id),
      Transaction.address_bytes(auth.address),
      encode_integer(auth.nonce),
      encode_integer(auth.y_parity),
      encode_integer(auth.r),
      encode_integer(auth.s)
    ]
  end

  defp encode_integer(0), do: <<>>

  defp encode_integer(value) when is_integer(value) and value > 0,
    do: :binary.encode_unsigned(value)
end
