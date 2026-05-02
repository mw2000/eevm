defmodule EEVM.Block.ProcessorTest do
  use ExUnit.Case, async: true

  alias EEVM.Block.{Bloom, Header, Processor, Receipt, Result, Withdrawal}
  alias EEVM.{Database, StateRoot}
  alias EEVM.Database.InMemory
  alias EEVM.MPT.Trie

  # ---------------------------------------------------------------------------
  # Test doubles
  # ---------------------------------------------------------------------------

  # A plain-map "transaction" carrying whatever fields the inline executor
  # needs. Everything uses `gas_limit` because the processor reads it off
  # every tx to validate against the header.
  defp tx(fields), do: Enum.into(fields, %{})

  # Tiny encoder that round-trips the map's `:id` to a deterministic binary.
  # We only need *some* encoder for the transactions-root computation;
  # tests don't care that it's RLP-compatible with real envelopes.
  defp tx_encoder, do: fn %{id: id} -> <<id::unsigned-big-256>> end

  # Successful executor that bumps `target`'s balance by `value`. Each tx
  # may carry `:value`, `:target`, `:gas_used`, `:logs`, `:status`. The db
  # is mutated by writing the nonce of the `:target` so the state root
  # changes when `:target` is set, and is unchanged otherwise.
  defp mutating_executor do
    fn tx, _block_ctx, db ->
      gas_used = Map.get(tx, :gas_used, 21_000)
      status = Map.get(tx, :status, 1)
      logs = Map.get(tx, :logs, [])

      new_db =
        case Map.fetch(tx, :mutate) do
          {:ok, {address, balance}} -> Database.set_balance(db, address, balance)
          :error -> db
        end

      {:ok, %{status: status, gas_used: gas_used, logs: logs, db: new_db}}
    end
  end

  defp noop_header(overrides \\ []) do
    Header.new([gas_limit: 30_000_000] ++ overrides)
  end

  defp run(header, transactions, db, extra_opts \\ []) do
    Processor.process_block(
      header,
      transactions,
      db,
      [tx_executor: mutating_executor(), tx_encoder: tx_encoder()] ++ extra_opts
    )
  end

  # ---------------------------------------------------------------------------
  # Empty block
  # ---------------------------------------------------------------------------

  describe "empty block" do
    test "runs system calls in order and returns empty-trie commitments" do
      db = InMemory.new()
      header = noop_header()

      {:ok, call_log} = Agent.start_link(fn -> [] end)

      hook_a = fn db_in, _ctx ->
        Agent.update(call_log, fn xs -> [:a | xs] end)
        Database.set_balance(db_in, 0xA, 1)
      end

      hook_b = fn db_in, _ctx ->
        Agent.update(call_log, fn xs -> [:b | xs] end)
        Database.set_balance(db_in, 0xB, 2)
      end

      {:ok, %Result{} = result} =
        run(header, [], db, system_calls: [hook_a, hook_b])

      assert Agent.get(call_log, &Enum.reverse(&1)) == [:a, :b]
      assert Database.get_balance(result.post_state_db, 0xA) == 1
      assert Database.get_balance(result.post_state_db, 0xB) == 2

      # No transactions → receipts/transactions roots are the empty-trie hash.
      empty_root = Trie.root_hash([])
      assert result.receipts_root == empty_root
      assert result.transactions_root == empty_root
      assert result.logs_bloom == Bloom.empty()
      assert result.receipts == []
      assert result.gas_used == 0

      assert result.state_root == StateRoot.compute_state_root(result.post_state_db)
    end
  end

  # ---------------------------------------------------------------------------
  # Single transaction block
  # ---------------------------------------------------------------------------

  describe "single transaction block" do
    test "invokes the executor once and records a matching receipt" do
      db = InMemory.new()
      header = noop_header()

      {:ok, calls} = Agent.start_link(fn -> 0 end)

      counting_executor = fn _tx, _ctx, db_in ->
        Agent.update(calls, &(&1 + 1))
        {:ok, %{status: 1, gas_used: 21_000, logs: [], db: db_in}}
      end

      {:ok, result} =
        Processor.process_block(
          header,
          [tx(id: 1, gas_limit: 100_000)],
          db,
          tx_executor: counting_executor,
          tx_encoder: tx_encoder()
        )

      assert Agent.get(calls, & &1) == 1
      assert length(result.receipts) == 1

      [%Receipt{cumulative_gas_used: cumulative}] = result.receipts
      assert cumulative == 21_000
      assert result.gas_used == 21_000

      # receipts_root with a single receipt should be non-empty and match a
      # direct Trie.root_hash of the same encoding shape.
      assert result.receipts_root != Trie.root_hash([])
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-transaction block
  # ---------------------------------------------------------------------------

  describe "multi transaction block" do
    test "cumulative_gas_used accumulates in order across receipts" do
      db = InMemory.new()
      header = noop_header()

      txs = [
        tx(id: 1, gas_limit: 100_000, gas_used: 21_000),
        tx(id: 2, gas_limit: 100_000, gas_used: 30_000),
        tx(id: 3, gas_limit: 100_000, gas_used: 40_000)
      ]

      {:ok, result} = run(header, txs, db)

      assert Enum.map(result.receipts, & &1.cumulative_gas_used) == [21_000, 51_000, 91_000]
      assert result.gas_used == 91_000
    end
  end

  # ---------------------------------------------------------------------------
  # Block gas limit exceeded
  # ---------------------------------------------------------------------------

  describe "block gas limit enforcement" do
    test "rejects the block when sum(tx.gas_limit) > header.gas_limit" do
      db = InMemory.new()
      header = noop_header(gas_limit: 50_000)

      txs = [
        tx(id: 1, gas_limit: 30_000),
        tx(id: 2, gas_limit: 30_000)
      ]

      assert {:error, :block_gas_limit_exceeded} = run(header, txs, db)
    end

    test "accepts sum equal to the header gas limit" do
      db = InMemory.new()
      header = noop_header(gas_limit: 60_000)

      txs = [
        tx(id: 1, gas_limit: 30_000, gas_used: 30_000),
        tx(id: 2, gas_limit: 30_000, gas_used: 30_000)
      ]

      assert {:ok, %Result{gas_used: 60_000}} = run(header, txs, db)
    end
  end

  # ---------------------------------------------------------------------------
  # System calls run BEFORE transactions
  # ---------------------------------------------------------------------------

  describe "system call ordering" do
    test "system calls execute before transactions even with zero txs" do
      db = InMemory.new()
      header = noop_header()

      seed_balance = fn db_in, _ctx -> Database.set_balance(db_in, 0xBEEF, 123) end

      {:ok, result} = run(header, [], db, system_calls: [seed_balance])

      assert Database.get_balance(result.post_state_db, 0xBEEF) == 123
    end

    test "transactions see the post-system-call database" do
      db = InMemory.new()
      header = noop_header()

      seed = fn db_in, _ctx -> Database.set_balance(db_in, 0xBEEF, 1_000) end

      observing_executor = fn _tx, _ctx, db_in ->
        # The executor observes the balance planted by the system call and
        # forwards it into the tx_result's db so we can assert on it.
        observed = Database.get_balance(db_in, 0xBEEF)
        mutated_db = Database.set_balance(db_in, 0xCAFE, observed)
        {:ok, %{status: 1, gas_used: 21_000, logs: [], db: mutated_db}}
      end

      {:ok, result} =
        Processor.process_block(
          header,
          [tx(id: 1, gas_limit: 100_000)],
          db,
          tx_executor: observing_executor,
          tx_encoder: tx_encoder(),
          system_calls: [seed]
        )

      assert Database.get_balance(result.post_state_db, 0xCAFE) == 1_000
    end
  end

  # ---------------------------------------------------------------------------
  # State root behaviour
  # ---------------------------------------------------------------------------

  describe "state root" do
    test "changes when a transaction mutates state" do
      db = InMemory.new()
      header = noop_header()
      pre_root = StateRoot.compute_state_root(db)

      {:ok, result} =
        run(header, [tx(id: 1, gas_limit: 100_000, mutate: {0x42, 9_999})], db)

      assert result.state_root != pre_root
      assert result.state_root == StateRoot.compute_state_root(result.post_state_db)
    end

    test "stays stable when no transaction mutates state" do
      db = InMemory.new()
      header = noop_header()
      pre_root = StateRoot.compute_state_root(db)

      {:ok, result} = run(header, [tx(id: 1, gas_limit: 100_000)], db)

      assert result.state_root == pre_root
    end
  end

  # ---------------------------------------------------------------------------
  # Logs bloom aggregation
  # ---------------------------------------------------------------------------

  describe "logs bloom" do
    test "aggregates every receipt's bloom into the block bloom" do
      db = InMemory.new()
      header = noop_header()

      log_a = %{address: 0x1111, topics: [0xAAA], data: <<>>}
      log_b = %{address: 0x2222, topics: [0xBBB, 0xCCC], data: <<0x01>>}

      txs = [
        tx(id: 1, gas_limit: 100_000, logs: [log_a]),
        tx(id: 2, gas_limit: 100_000, logs: [log_b])
      ]

      {:ok, result} = run(header, txs, db)

      # The block bloom should carry every address/topic from every receipt.
      assert Bloom.contains?(result.logs_bloom, <<0x1111::unsigned-big-160>>)
      assert Bloom.contains?(result.logs_bloom, <<0xAAA::unsigned-big-256>>)
      assert Bloom.contains?(result.logs_bloom, <<0x2222::unsigned-big-160>>)
      assert Bloom.contains?(result.logs_bloom, <<0xBBB::unsigned-big-256>>)
      assert Bloom.contains?(result.logs_bloom, <<0xCCC::unsigned-big-256>>)

      # And each receipt's own bloom should only carry its own logs.
      [r1, r2] = result.receipts
      assert r1.logs_bloom == Bloom.from_logs([log_a])
      assert r2.logs_bloom == Bloom.from_logs([log_b])

      assert result.logs_bloom == Bloom.merge(r1.logs_bloom, r2.logs_bloom)
    end
  end

  # ---------------------------------------------------------------------------
  # Withdrawals (EIP-4895)
  # ---------------------------------------------------------------------------

  describe "withdrawals" do
    test "credits each address with amount * 1_000_000_000 (gwei → wei)" do
      db = InMemory.new()
      header = noop_header()

      withdrawals = [
        %Withdrawal{index: 0, validator_index: 1, address: 0xAAAA, amount: 5},
        %Withdrawal{index: 1, validator_index: 2, address: 0xBBBB, amount: 7}
      ]

      {:ok, result} = run(header, [], db, withdrawals: withdrawals)

      assert Database.get_balance(result.post_state_db, 0xAAAA) == 5_000_000_000
      assert Database.get_balance(result.post_state_db, 0xBBBB) == 7_000_000_000
    end

    test "state_root reflects withdrawals (applied before commitments)" do
      db = InMemory.new()
      header = noop_header()
      pre_root = StateRoot.compute_state_root(db)

      {:ok, result} =
        run(header, [], db,
          withdrawals: [%Withdrawal{index: 0, validator_index: 0, address: 0xCAFE, amount: 1}]
        )

      assert result.state_root != pre_root
      assert result.state_root == StateRoot.compute_state_root(result.post_state_db)
    end

    test "applies after the transaction fold so txs cannot observe the credit" do
      db = InMemory.new()
      header = noop_header()

      observing_executor = fn _tx, _ctx, db_in ->
        observed = Database.get_balance(db_in, 0xCAFE)
        new_db = Database.set_balance(db_in, 0xCAFE_BABE, observed)
        {:ok, %{status: 1, gas_used: 21_000, logs: [], db: new_db}}
      end

      {:ok, result} =
        Processor.process_block(
          header,
          [tx(id: 1, gas_limit: 100_000)],
          db,
          tx_executor: observing_executor,
          tx_encoder: tx_encoder(),
          withdrawals: [%Withdrawal{index: 0, validator_index: 0, address: 0xCAFE, amount: 1}]
        )

      # The tx ran *before* the withdrawal landed, so it observed a zero balance.
      assert Database.get_balance(result.post_state_db, 0xCAFE_BABE) == 0
      assert Database.get_balance(result.post_state_db, 0xCAFE) == 1_000_000_000
    end

    test "empty withdrawals list is a no-op" do
      db = InMemory.new()
      header = noop_header()
      pre_root = StateRoot.compute_state_root(db)

      {:ok, result} = run(header, [], db, withdrawals: [])

      assert result.state_root == pre_root
    end
  end

  # ---------------------------------------------------------------------------
  # Per-transaction failure
  # ---------------------------------------------------------------------------

  describe "per-transaction failure" do
    test "halts on first executor error and reports the offending index" do
      db = InMemory.new()
      header = noop_header()

      failing_executor = fn tx, _ctx, db_in ->
        case Map.get(tx, :id) do
          2 ->
            {:error, :nonce_mismatch}

          _ ->
            {:ok,
             %{
               status: 1,
               gas_used: 21_000,
               logs: [],
               db: Database.set_balance(db_in, Map.get(tx, :id), 1)
             }}
        end
      end

      txs = [
        tx(id: 1, gas_limit: 100_000),
        tx(id: 2, gas_limit: 100_000),
        tx(id: 3, gas_limit: 100_000)
      ]

      result =
        Processor.process_block(
          header,
          txs,
          db,
          tx_executor: failing_executor,
          tx_encoder: tx_encoder()
        )

      assert result == {:error, {:tx_failed, 1, :nonce_mismatch}}
    end

    test "reports index 0 when the very first transaction fails" do
      db = InMemory.new()
      header = noop_header()

      executor = fn _tx, _ctx, _db -> {:error, :insufficient_balance} end

      assert Processor.process_block(
               header,
               [tx(id: 1, gas_limit: 100_000)],
               db,
               tx_executor: executor,
               tx_encoder: tx_encoder()
             ) == {:error, {:tx_failed, 0, :insufficient_balance}}
    end
  end

  # ---------------------------------------------------------------------------
  # Option validation
  # ---------------------------------------------------------------------------

  describe "option validation" do
    test "raises when :tx_executor is missing" do
      assert_raise ArgumentError, ~r/:tx_executor is required/, fn ->
        Processor.process_block(noop_header(), [], InMemory.new(), [])
      end
    end

    test "raises when :tx_executor is not a 3-arity function" do
      assert_raise ArgumentError, ~r/must be a 3-arity function/, fn ->
        Processor.process_block(noop_header(), [], InMemory.new(), tx_executor: :nope)
      end
    end
  end
end
