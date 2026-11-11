defmodule EEVM.DatabaseTest do
  use ExUnit.Case, async: true

  alias EEVM.{BlockEnv, Database, StateChanges}
  alias EEVM.Crypto.{ECDSA, Keccak}
  alias EEVM.Database.InMemory
  alias EEVM.Transaction.{Legacy, Signer}

  doctest Database
  doctest InMemory

  # A read-only backend over a map that can't commit or enumerate. A `:fail`
  # entry makes that read return an error.
  defmodule ReadOnly do
    @behaviour EEVM.Database

    @impl true
    def account(state, address), do: lookup(state, {:account, address}, nil)
    @impl true
    def code(state, hash), do: lookup(state, {:code, hash}, <<>>)
    @impl true
    def storage(state, address, slot), do: lookup(state, {:storage, address, slot}, 0)
    @impl true
    def block_hash(state, number), do: lookup(state, {:block_hash, number}, nil)
    @impl true
    def commit(_state, _changes), do: {:error, :unsupported}
    @impl true
    def accounts(_state), do: {:error, :unsupported}
    @impl true
    def storage_slots(state, address), do: lookup(state, {:storage_slots, address}, :unsupported)

    defp lookup(state, key, default) do
      case Map.get(state, key, default) do
        :fail -> {:error, :backend_down}
        :unsupported -> {:error, :unsupported}
        value -> {:ok, value}
      end
    end
  end

  # A read-only backend that answers :not_supported, the atom the adapter
  # guide's RPC example used before #219, instead of :unsupported.
  defmodule NotSupported do
    @behaviour EEVM.Database

    @impl true
    defdelegate account(state, address), to: ReadOnly
    @impl true
    defdelegate code(state, hash), to: ReadOnly
    @impl true
    defdelegate storage(state, address, slot), to: ReadOnly
    @impl true
    defdelegate block_hash(state, number), to: ReadOnly
    @impl true
    def commit(_state, _changes), do: {:error, :not_supported}
    @impl true
    def accounts(_state), do: {:error, :not_supported}
    @impl true
    def storage_slots(_state, _address), do: {:error, :not_supported}
  end

  # A backend written for the first read-only behaviour (before #204): commit/2,
  # accounts/1 and storage_slots/2 were optional, and the enumerations returned
  # bare lists. No @behaviour, so leaving callbacks out doesn't warn.
  defmodule StepSix do
    def account(state, address), do: {:ok, Map.get(state.accounts, address)}
    def code(_state, _hash), do: {:ok, <<>>}
    def storage(state, address, slot), do: {:ok, Map.get(state.storage, {address, slot}, 0)}
    def block_hash(_state, _number), do: {:ok, nil}
    def accounts(state), do: Map.keys(state.accounts)
  end

  # A backend written against the pre-1.0 callbacks.
  defmodule OldStyle do
    def get_account(state, address), do: Map.get(state.accounts, address)
    def account_exists?(state, address), do: Map.has_key?(state.accounts, address)
    def get_code(state, address), do: state |> get_account(address) |> field(:code, <<>>)
    def get_balance(state, address), do: state |> get_account(address) |> field(:balance, 0)
    def get_nonce(state, address), do: state |> get_account(address) |> field(:nonce, 0)
    def storage_load(state, address, key), do: Map.get(state.storage, {address, key}, 0)
    def put_account(state, address, account), do: put_in(state.accounts[address], account)

    def storage_store(state, address, key, value),
      do: put_in(state.storage[{address, key}], value)

    def account_addresses(state), do: Map.keys(state.accounts)
    def storage_addresses(_state), do: []
    def storage_slots(_state, _address), do: []

    def delete_account(state, address),
      do: %{state | accounts: Map.delete(state.accounts, address)}

    defp field(nil, _key, default), do: default
    defp field(account, key, default), do: Map.get(account, key, default)
  end

  @private_key <<0x46::256>>
  @recipient 0xB0B

  defp sender do
    {:ok, {x, y}} = ECDSA.public_key(:secp256k1, @private_key)
    <<_::binary-size(12), address::unsigned-big-160>> = Keccak.hash_256(<<x::256, y::256>>)
    address
  end

  defp transfer_tx do
    tx = %Legacy{gas_price: 1, gas_limit: 21_000, to: @recipient, value: 1_000}
    {:ok, signed} = Signer.sign(tx, @private_key, EEVM.Config.new(:cancun))
    signed
  end

  defp block, do: BlockEnv.new(gas_limit: 30_000_000, coinbase: 0xC0FFEE)

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
      assert Database.get_account(db, 1) == %{balance: 50, nonce: 0, code: <<0xAA>>}
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

    test "transfer to self leaves the balance unchanged" do
      db = InMemory.new(accounts: %{1 => %{balance: 100}})
      assert {:ok, db} = Database.transfer(db, 1, 1, 30)
      assert Database.get_balance(db, 1) == 100
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

    test "account_addresses/1 returns all account keys" do
      db = InMemory.new(accounts: %{0xAA => %{balance: 1}, 0xBB => %{nonce: 2}})

      assert db |> Database.account_addresses() |> Enum.sort() == [0xAA, 0xBB]
    end

    test "storage_slots/2 returns tracked slot entries" do
      db = InMemory.new(storage: %{0xAA => %{0 => 10, 9 => 11}})

      assert db |> Database.storage_slots(0xAA) |> Enum.sort() == [{0, 10}, {9, 11}]
      assert Database.storage_slots(db, 0xBB) == []
    end
  end

  describe "read-only backends" do
    test "transact runs against reads only and returns its writes as changes, uncommitted" do
      state = %{{:account, sender()} => %{balance: 10 ** 18, nonce: 0, code: <<>>}}
      db = Database.new(ReadOnly, state)

      assert {:ok, result} = EEVM.transact(transfer_tx(), block(), db)
      assert result.status == :success
      # commit/2 is unsupported: the writes stay in the overlay and the backend is untouched.
      assert result.db.state == state
      assert Database.get_balance(result.db, @recipient) == 1_000
      assert Database.commit(result.db) == {:error, :commit_not_supported}

      %StateChanges{accounts: changes} = result.changes
      assert changes[@recipient].balance == 1_000
      assert changes[sender()].nonce == 1
      assert changes[sender()].balance == 10 ** 18 - 1_000 - 21_000
      assert Map.keys(changes) |> Enum.sort() == Enum.sort([@recipient, sender(), 0xC0FFEE])
    end

    test "a failed read returns {:error, {:database, reason}} from every entry point" do
      # SLOAD of slot 0.
      code = <<0x60, 0x00, 0x54, 0x00>>
      db = Database.new(ReadOnly, %{{:storage, 0xA, 0} => :fail})

      assert EEVM.run(code, address: 0xA, db: db) == {:error, {:database, :backend_down}}

      failing_sender = Database.new(ReadOnly, %{{:account, sender()} => :fail})

      assert EEVM.transact(transfer_tx(), block(), failing_sender) ==
               {:error, {:database, :backend_down}}

      assert_raise Database.ReadError, fn -> Database.storage_load(db, 0xA, 0) end

      failing_slots = Database.new(ReadOnly, %{{:storage_slots, 0xA} => :fail})
      assert_raise Database.ReadError, fn -> Database.storage_slots(failing_slots, 0xA) end
    end

    test "unsupported enumerations see only the overlay" do
      db = ReadOnly |> Database.new(%{}) |> Database.storage_store(0xA, 1, 2)

      assert Database.storage_slots(db, 0xA) == [{1, 2}]
      assert Database.account_addresses(db) == [0xA]
    end

    test "a backend without the #204 callbacks still runs, enumerates, and doesn't commit" do
      state = %{accounts: %{sender() => %{balance: 10 ** 18, nonce: 0, code: <<>>}}, storage: %{}}
      db = Database.new(StepSix, state)
      assert db.impl == StepSix

      assert {:ok, result} = EEVM.transact(transfer_tx(), block(), db)
      assert result.db.state == state
      assert Database.commit(result.db) == {:error, :commit_not_supported}
      # The bare list from accounts/1 is accepted; storage_slots/2 is missing.
      assert sender() in Database.account_addresses(result.db)
      assert Database.storage_slots(result.db, sender()) == []
    end

    test "a backend answering :not_supported is treated as :unsupported (deprecated)" do
      state = %{{:account, sender()} => %{balance: 10 ** 18, nonce: 0, code: <<>>}}

      assert {:ok, result} =
               EEVM.transact(transfer_tx(), block(), Database.new(NotSupported, state))

      assert result.db.state == state
      assert Database.commit(result.db) == {:error, :commit_not_supported}

      db = result.db |> Database.storage_store(0xA, 1, 2)
      assert Database.storage_slots(db, 0xA) == [{1, 2}]
      assert 0xA in Database.account_addresses(db)
    end

    test "code is fetched by hash only when it isn't returned with the account" do
      code = <<0x60, 0x07, 0x00>>
      hash = Keccak.hash_256(code)

      state = %{
        {:account, 0xC} => %{balance: 0, nonce: 1, code_hash: hash},
        {:code, hash} => code
      }

      assert Database.get_code(Database.new(ReadOnly, state), 0xC) == code
      assert Database.get_code_hash(Database.new(ReadOnly, state), 0xC) == hash
    end
  end

  describe "overlay and commit" do
    test "run/2 lists its writes in changes and never commits them" do
      # PUSH1 5 PUSH1 0 SSTORE STOP
      db = InMemory.new()
      assert {:ok, result} = EEVM.run(<<0x60, 5, 0x60, 0, 0x55, 0x00>>, address: 0xA, db: db)

      assert result.db.state == db.state
      assert %{0xA => %{storage: %{0 => 5}}} = result.changes.accounts
    end

    test "transact commits to an InMemory backend, leaving an empty overlay" do
      db = InMemory.new(accounts: %{sender() => %{balance: 10 ** 18}})

      assert {:ok, result} = EEVM.transact(transfer_tx(), block(), db)
      assert result.db.accounts == %{} and result.db.storage == %{}
      assert result.db.state.accounts[@recipient].balance == 1_000
      assert result.changes.accounts[@recipient].balance == 1_000
    end

    test "deleting an account hides its old storage, and commit clears it" do
      db = InMemory.new(accounts: %{0xA => %{nonce: 1}}, storage: %{0xA => %{0 => 1, 1 => 2}})

      db = db |> Database.delete_account(0xA) |> Database.set_nonce(0xA, 1)
      db = Database.storage_store(db, 0xA, 1, 9)

      assert Database.storage_load(db, 0xA, 0) == 0
      assert Database.storage_load(db, 0xA, 1) == 9
      assert %{destroyed?: true, storage: %{1 => 9}} = Database.changes(db).accounts[0xA]

      {:ok, committed} = Database.commit(db)
      assert Database.storage_slots(committed, 0xA) == [{1, 9}]
    end

    test "a deleted account commits as :destroyed and a zero write clears its slot" do
      db =
        InMemory.new(accounts: %{0xA => %{balance: 1}, 0xB => %{}}, storage: %{0xB => %{3 => 4}})

      db = db |> Database.delete_account(0xA) |> Database.storage_store(0xB, 3, 0)

      assert Database.changes(db).accounts[0xA] == :destroyed

      {:ok, committed} = Database.commit(db)
      refute Database.account_exists?(committed, 0xA)
      assert Database.storage_slots(committed, 0xB) == []
      assert committed.state.storage == %{}
    end

    test "a backend with the pre-1.0 callbacks is wrapped and still commits" do
      state = %{accounts: %{sender() => %{balance: 10 ** 18}}, storage: %{}}
      db = Database.new(OldStyle, state)
      assert db.impl == EEVM.Database.Legacy

      assert {:ok, result} = EEVM.transact(transfer_tx(), block(), db)
      {OldStyle, committed} = result.db.state
      assert OldStyle.get_balance(committed, @recipient) == 1_000
      assert OldStyle.get_nonce(committed, sender()) == 1
    end
  end

  describe "block hashes" do
    # PUSH1 99 BLOCKHASH STOP. BLOCKHASH sees the 256 blocks before the current one.
    @blockhash_99 <<0x60, 99, 0x40, 0x00>>

    test "BLOCKHASH falls back to the backend for a recent block the environment lacks" do
      db = InMemory.new(block_hashes: %{99 => <<0xAA::256>>})

      assert {:ok, %{stack: [0xAA]}} =
               EEVM.run(@blockhash_99,
                 address: 0xA,
                 db: db,
                 block: BlockEnv.new(number: 355),
                 debug: true
               )

      assert {:ok, %{stack: [0]}} =
               EEVM.run(@blockhash_99,
                 address: 0xA,
                 db: db,
                 block: BlockEnv.new(number: 356),
                 debug: true
               )

      assert {:ok, %{stack: [0xBB]}} =
               EEVM.run(@blockhash_99,
                 address: 0xA,
                 db: db,
                 block: BlockEnv.new(number: 100, block_hashes: %{99 => <<0xBB::256>>}),
                 debug: true
               )
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

    test "inspects as its backend and its pending writes, never the backend state" do
      db = InMemory.new(accounts: %{0xBEEF => %{balance: 123_456_789}})
      assert inspect(db) == "#EEVM.Database<EEVM.Database.InMemory, no pending writes>"

      db = db |> Database.set_balance(0xA, 1) |> Database.storage_store(0xB, 7, 9)

      assert inspect(db) ==
               "#EEVM.Database<EEVM.Database.InMemory, pending writes to 2 accounts and 1 storage slot>"

      # A result shows its database the same way, and once: the deprecated copy is hidden.
      {:ok, result} =
        EEVM.transact(
          transfer_tx(),
          block(),
          InMemory.new(accounts: %{sender() => %{balance: 10 ** 18}})
        )

      printed = inspect(result, limit: :infinity)
      assert printed =~ "db: #EEVM.Database<EEVM.Database.InMemory, no pending writes>"
      refute printed =~ "post_state_db"
    end
  end
end
