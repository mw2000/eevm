defmodule EEVM.StateRootTest do
  use ExUnit.Case, async: true

  alias EEVM.Database.InMemory
  alias EEVM.MPT.Trie
  alias EEVM.StateRoot

  test "compute_storage_root/2 returns empty trie hash for empty storage" do
    db = InMemory.new()

    assert StateRoot.compute_storage_root(db, 0xAA) == Trie.secure_root_hash([])
  end

  test "compute_storage_root/2 includes only non-zero slots" do
    db =
      InMemory.new(storage: %{
        0xAA => %{
          0 => 0,
          1 => 42,
          5 => 999
        }
      })

    expected =
      Trie.secure_root_hash([
        {encode_uint(1, 32), ExRLP.encode(42)},
        {encode_uint(5, 32), ExRLP.encode(999)}
      ])

    assert StateRoot.compute_storage_root(db, 0xAA) == expected
  end

  test "compute_state_root/1 returns empty trie hash for empty world state" do
    db = InMemory.new()

    assert StateRoot.compute_state_root(db) == Trie.secure_root_hash([])
  end

  test "compute_state_root/1 computes root from account tuple" do
    address = 0x1234

    db =
      InMemory.new(accounts: %{address => %{balance: 7, nonce: 3, code: <<0x60, 0x00, 0x00>>}})

    storage_root = Trie.secure_root_hash([])
    code_hash = ExKeccak.hash_256(<<0x60, 0x00, 0x00>>)
    account_value = ExRLP.encode([3, 7, storage_root, code_hash])

    expected = Trie.secure_root_hash([{encode_uint(address, 20), account_value}])

    assert StateRoot.compute_state_root(db) == expected
  end

  test "compute_state_root/1 includes storage-backed accounts" do
    address = 0xCAFE

    db =
      InMemory.new(
        storage: %{
          address => %{9 => 1, 10 => 0}
        }
      )

    storage_root = Trie.secure_root_hash([{encode_uint(9, 32), ExRLP.encode(1)}])
    code_hash = ExKeccak.hash_256(<<>>)
    account_value = ExRLP.encode([0, 0, storage_root, code_hash])

    expected = Trie.secure_root_hash([{encode_uint(address, 20), account_value}])

    assert StateRoot.compute_state_root(db) == expected
  end

  defp encode_uint(value, bytes) do
    encoded = :binary.encode_unsigned(value)
    <<0::size((bytes - byte_size(encoded)) * 8), encoded::binary>>
  end
end
