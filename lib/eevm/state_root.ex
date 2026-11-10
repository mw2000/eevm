defmodule EEVM.StateRoot do
  @moduledoc """
  Computes Ethereum storage roots and state roots from the current `EEVM.Database`.

  Both enumerate the backend, so it must implement the optional
  `c:EEVM.Database.accounts/1` and `c:EEVM.Database.storage_slots/2`.
  """

  alias EEVM.Database
  alias EEVM.MPT.Trie

  @storage_key_bytes 32
  @address_bytes 20

  @doc "Returns the storage trie root of `address`."
  @spec compute_storage_root(Database.t(), non_neg_integer()) :: binary()
  def compute_storage_root(%Database{} = db, address) when is_integer(address) and address >= 0 do
    entries =
      db
      |> Database.storage_slots(address)
      |> Enum.reject(fn {_slot, value} -> value == 0 end)
      |> Enum.sort_by(fn {slot, _value} -> slot end)
      |> Enum.map(fn {slot, value} ->
        {encode_uint(slot, @storage_key_bytes), ExRLP.encode(value)}
      end)

    Trie.secure_root_hash(entries)
  end

  @doc "Returns the world-state trie root of `db`, overlay included."
  @spec compute_state_root(Database.t()) :: binary()
  def compute_state_root(%Database{} = db) do
    entries =
      db
      |> Database.account_addresses()
      |> Enum.sort()
      |> Enum.map(fn address ->
        {encode_uint(address, @address_bytes), encode_account(db, address)}
      end)

    Trie.secure_root_hash(entries)
  end

  defp encode_account(db, address) do
    nonce = Database.get_nonce(db, address)
    balance = Database.get_balance(db, address)
    storage_root = compute_storage_root(db, address)
    code_hash = Database.get_code_hash(db, address) || ExKeccak.hash_256(<<>>)

    ExRLP.encode([nonce, balance, storage_root, code_hash])
  end

  defp encode_uint(value, bytes) when is_integer(value) and value >= 0 do
    encoded = :binary.encode_unsigned(value)

    cond do
      byte_size(encoded) == bytes -> encoded
      byte_size(encoded) < bytes -> <<0::size((bytes - byte_size(encoded)) * 8), encoded::binary>>
      true -> binary_part(encoded, byte_size(encoded) - bytes, bytes)
    end
  end
end
