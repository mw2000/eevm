defmodule EEVM.StateRoot do
  @moduledoc """
  Computes Ethereum storage roots and state roots from the current `EEVM.Database`.
  """

  alias EEVM.Database
  alias EEVM.MPT.Trie

  @storage_key_bytes 32
  @address_bytes 20

  @spec compute_storage_root(Database.t(), non_neg_integer()) :: binary()
  def compute_storage_root(%Database{} = db, address) when is_integer(address) and address >= 0 do
    entries =
      db
      |> Database.storage_slots(address)
      |> Enum.reject(fn {_slot, value} -> value == 0 end)
      |> Enum.sort_by(fn {slot, _value} -> slot end)
      |> Enum.map(fn {slot, value} -> {encode_uint(slot, @storage_key_bytes), ExRLP.encode(value)} end)

    Trie.secure_root_hash(entries)
  end

  @spec compute_state_root(Database.t()) :: binary()
  def compute_state_root(%Database{} = db) do
    account_addresses =
      db
      |> Database.account_addresses()
      |> Enum.concat(storage_backed_addresses(db))
      |> Enum.uniq()
      |> Enum.sort()

    entries =
      Enum.map(account_addresses, fn address ->
        {encode_uint(address, @address_bytes), encode_account(db, address)}
      end)

    Trie.secure_root_hash(entries)
  end

  defp encode_account(db, address) do
    nonce = Database.get_nonce(db, address)
    balance = Database.get_balance(db, address)
    storage_root = compute_storage_root(db, address)
    code_hash = ExKeccak.hash_256(Database.get_code(db, address))

    ExRLP.encode([nonce, balance, storage_root, code_hash])
  end

  defp storage_backed_addresses(db) do
    db
    |> Database.storage_addresses()
    |> Enum.flat_map(fn address ->
      case Database.storage_slots(db, address) |> Enum.reject(fn {_slot, value} -> value == 0 end) do
        [] -> []
        _slots -> [address]
      end
    end)
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
