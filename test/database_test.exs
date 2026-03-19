defmodule EEVM.DatabaseTest do
  use ExUnit.Case, async: true

  alias EEVM.Database
  alias EEVM.Database.InMemory

  describe "InMemory.new/1" do
    test "creates empty database" do
      db = InMemory.new()
      assert %Database{impl: InMemory} = db
    end

    test "creates database with initial accounts" do
      db = InMemory.new(accounts: %{1 => %{balance: 100, nonce: 5}})
      assert Database.get_balance(db, 1) == 100
      assert Database.get_nonce(db, 1) == 5
    end

    test "creates database with initial storage" do
      db = InMemory.new(storage: %{0xAA => %{0 => 42, 1 => 99}})
      assert Database.storage_load(db, 0xAA, 0) == 42
      assert Database.storage_load(db, 0xAA, 1) == 99
    end
  end

  describe "account reads" do
    test "get_account returns nil for non-existent address" do
      db = InMemory.new()
      assert Database.get_account(db, 1) == nil
    end

    test "get_account returns account map" do
      db = InMemory.new(accounts: %{1 => %{balance: 50, code: <<0xAA>>}})
      assert Database.get_account(db, 1) == %{balance: 50, code: <<0xAA>>}
    end

    test "account_exists? returns false for missing accounts" do
      db = InMemory.new()
      refute Database.account_exists?(db, 1)
    end

    test "account_exists? returns true for existing accounts" do
      db = InMemory.new(accounts: %{1 => %{}})
      assert Database.account_exists?(db, 1)
    end

    test "get_code returns empty binary for non-existent account" do
      db = InMemory.new()
      assert Database.get_code(db, 1) == <<>>
    end

    test "get_code returns empty binary when account has no code" do
      db = InMemory.new(accounts: %{1 => %{balance: 10}})
      assert Database.get_code(db, 1) == <<>>
    end

    test "get_code returns code when present" do
      db = InMemory.new(accounts: %{1 => %{code: <<0xFE, 0xFF>>}})
      assert Database.get_code(db, 1) == <<0xFE, 0xFF>>
    end

    test "get_balance returns 0 for non-existent account" do
      db = InMemory.new()
      assert Database.get_balance(db, 1) == 0
    end

    test "get_balance returns balance when present" do
      db = InMemory.new(accounts: %{1 => %{balance: 1_000}})
      assert Database.get_balance(db, 1) == 1_000
    end

    test "get_nonce returns 0 for non-existent account" do
      db = InMemory.new()
      assert Database.get_nonce(db, 1) == 0
    end

    test "get_nonce returns nonce when present" do
      db = InMemory.new(accounts: %{1 => %{nonce: 42}})
      assert Database.get_nonce(db, 1) == 42
    end
  end

  describe "account writes" do
    test "put_account creates a new account" do
      db = InMemory.new()
      db = Database.put_account(db, 1, %{balance: 100})
      assert Database.get_balance(db, 1) == 100
    end

    test "put_account replaces existing account" do
      db = InMemory.new(accounts: %{1 => %{balance: 50}})
      db = Database.put_account(db, 1, %{balance: 200, code: <<0xAA>>})
      assert Database.get_balance(db, 1) == 200
      assert Database.get_code(db, 1) == <<0xAA>>
    end

    test "delete_account removes account entirely" do
      db = InMemory.new(accounts: %{1 => %{balance: 100, code: <<0xFF>>}})
      db = Database.delete_account(db, 1)
      refute Database.account_exists?(db, 1)
      assert Database.get_account(db, 1) == nil
    end

    test "put_code sets code on existing account" do
      db = InMemory.new(accounts: %{1 => %{balance: 50}})
      db = Database.put_code(db, 1, <<0xAA, 0xBB>>)
      assert Database.get_code(db, 1) == <<0xAA, 0xBB>>
      assert Database.get_balance(db, 1) == 50
    end

    test "put_code creates account if non-existent" do
      db = InMemory.new()
      db = Database.put_code(db, 1, <<0xCC>>)
      assert Database.get_code(db, 1) == <<0xCC>>
    end

    test "set_balance updates balance" do
      db = InMemory.new(accounts: %{1 => %{balance: 50}})
      db = Database.set_balance(db, 1, 200)
      assert Database.get_balance(db, 1) == 200
    end

    test "set_balance creates account if non-existent" do
      db = InMemory.new()
      db = Database.set_balance(db, 1, 999)
      assert Database.get_balance(db, 1) == 999
    end

    test "set_nonce updates nonce" do
      db = InMemory.new(accounts: %{1 => %{nonce: 3}})
      db = Database.set_nonce(db, 1, 10)
      assert Database.get_nonce(db, 1) == 10
    end

    test "increment_nonce increments by 1" do
      db = InMemory.new(accounts: %{1 => %{nonce: 5}})
      db = Database.increment_nonce(db, 1)
      assert Database.get_nonce(db, 1) == 6
    end

    test "increment_nonce starts from 0 for non-existent account" do
      db = InMemory.new()
      db = Database.increment_nonce(db, 1)
      assert Database.get_nonce(db, 1) == 1
    end
  end

  describe "transfer" do
    test "transfers balance between accounts" do
      db = InMemory.new(accounts: %{1 => %{balance: 100}, 2 => %{balance: 50}})
      assert {:ok, db} = Database.transfer(db, 1, 2, 30)
      assert Database.get_balance(db, 1) == 70
      assert Database.get_balance(db, 2) == 80
    end

    test "transfer of 0 is a no-op" do
      db = InMemory.new(accounts: %{1 => %{balance: 100}})
      assert {:ok, ^db} = Database.transfer(db, 1, 2, 0)
    end

    test "transfer fails with insufficient balance" do
      db = InMemory.new(accounts: %{1 => %{balance: 10}})
      assert {:error, :insufficient_balance} = Database.transfer(db, 1, 2, 20)
    end

    test "transfer to non-existent account creates it" do
      db = InMemory.new(accounts: %{1 => %{balance: 50}})
      assert {:ok, db} = Database.transfer(db, 1, 2, 25)
      assert Database.get_balance(db, 2) == 25
    end
  end

  describe "storage" do
    test "storage_load returns 0 for uninitialized slot" do
      db = InMemory.new()
      assert Database.storage_load(db, 0xAA, 0) == 0
    end

    test "storage_load returns stored value" do
      db = InMemory.new(storage: %{0xAA => %{0 => 42}})
      assert Database.storage_load(db, 0xAA, 0) == 42
    end

    test "storage_store writes value" do
      db = InMemory.new()
      db = Database.storage_store(db, 0xAA, 0, 42)
      assert Database.storage_load(db, 0xAA, 0) == 42
    end

    test "storage_store masks to 256 bits" do
      import Bitwise
      db = InMemory.new()
      big_val = 1 <<< 256
      db = Database.storage_store(db, 0xAA, 0, big_val)
      assert Database.storage_load(db, 0xAA, 0) == 0
    end

    test "storage is address-scoped" do
      db = InMemory.new()
      db = Database.storage_store(db, 0xAA, 0, 111)
      db = Database.storage_store(db, 0xBB, 0, 222)
      assert Database.storage_load(db, 0xAA, 0) == 111
      assert Database.storage_load(db, 0xBB, 0) == 222
    end

    test "storage_store overwrites previous value" do
      db = InMemory.new(storage: %{0xAA => %{0 => 10}})
      db = Database.storage_store(db, 0xAA, 0, 99)
      assert Database.storage_load(db, 0xAA, 0) == 99
    end
  end

  describe "Database struct" do
    test "returns %Database{} from all write operations" do
      db = InMemory.new()
      assert %Database{} = Database.put_account(db, 1, %{balance: 1})
      assert %Database{} = Database.delete_account(db, 1)
      assert %Database{} = Database.put_code(db, 1, <<>>)
      assert %Database{} = Database.set_balance(db, 1, 0)
      assert %Database{} = Database.set_nonce(db, 1, 0)
      assert %Database{} = Database.increment_nonce(db, 1)
      assert {:ok, %Database{}} = Database.transfer(db, 1, 2, 0)
      assert %Database{} = Database.storage_store(db, 1, 0, 0)
    end
  end
end
