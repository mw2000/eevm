defmodule Devx.EtsDatabaseTest do
  use ExUnit.Case, async: true

  alias Devx.{EtsDatabase, ReadOnlyDatabase, Transactions}

  @recipient 0xB0B

  defp run_both(db) do
    {:ok, legacy} = Transactions.legacy(0, @recipient, 1_000)
    {:ok, typed} = Transactions.eip1559(1, @recipient, 1)
    {:ok, first} = Transactions.execute(legacy, db)
    {:ok, second} = Transactions.execute(typed, first.db)
    second
  end

  test "transactions commit to the table and agree with InMemory on the state root" do
    table = :ets.new(:state, [:set, :public])
    EtsDatabase.seed(table, Devx.sender(), %{balance: 10 ** 18, nonce: 0, code: <<>>})

    ets = run_both(EtsDatabase.new(table))
    in_memory = run_both(Devx.funded_db())

    assert [{_, %{balance: 1_001, nonce: 0}}] = :ets.lookup(table, {:account, @recipient})
    assert [{_, %{nonce: 2}}] = :ets.lookup(table, {:account, Devx.sender()})

    assert EEVM.StateRoot.compute_state_root(ets.db) ==
             EEVM.StateRoot.compute_state_root(in_memory.db)

    # A fresh wrapper over the same table sees the committed state.
    assert Transactions.balance(EtsDatabase.new(table), @recipient) == 1_001
  end

  test "a read-only adapter defines only the reads; results keep the writes" do
    table = :ets.new(:state, [:set, :public])
    EtsDatabase.seed(table, Devx.sender(), %{balance: 10 ** 18, nonce: 0, code: <<>>})

    {:ok, legacy} = Transactions.legacy(0, @recipient, 1_000)
    {:ok, result} = Transactions.execute(legacy, ReadOnlyDatabase.new(table))

    assert result.status == :success
    assert Transactions.balance(result.db, @recipient) == 1_000
    assert result.changes.accounts[@recipient].balance == 1_000
    assert EEVM.Database.commit(result.db) == {:error, :commit_not_supported}
    # The table holds only the seed.
    assert :ets.lookup(table, {:account, @recipient}) == []
  end

  test "contract storage lands in the table" do
    table = :ets.new(:state, [:set, :public])
    {:ok, token, _db, _logs} = Devx.Erc20.deploy(EtsDatabase.new(table), 0xA11CE, 77)

    # create/3 commits nothing; deploy into the table through a transaction instead.
    assert :ets.lookup(table, {:account, token}) == []

    EtsDatabase.seed(table, Devx.sender(), %{balance: 10 ** 18, nonce: 0, code: <<>>})
    [deploy | _] = Devx.Blocks.transactions(Devx.config())
    {:ok, result} = Transactions.execute(deploy, EtsDatabase.new(table))

    assert result.status == :success

    assert Devx.Erc20.balance_of(EtsDatabase.new(table), result.contract_address, Devx.sender()) ==
             500

    assert :ets.select_count(table, [{{{:storage, result.contract_address, :_}, :_}, [], [true]}]) >
             0
  end
end
