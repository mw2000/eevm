defmodule EEVM.Interpreter.JournalTest do
  use ExUnit.Case, async: true

  alias EEVM.Database.InMemory
  alias EEVM.Interpreter.{Journal, MachineState}

  describe "merge_child_result/2 — successful child" do
    test "promotes child's revertible fields onto the parent" do
      parent = parent_state()
      parent_db = parent.db

      child_db = InMemory.new() |> seed_account(0xCAFE, 100)

      child = %{
        parent
        | status: :stopped,
          db: child_db,
          accessed_addresses: MapSet.new([0xAA]),
          accessed_storage_keys: MapSet.new([{0xAA, 0x01}]),
          created_addresses: MapSet.new([0xCAFE]),
          touched_addresses: MapSet.new([0xCAFE])
      }

      merged = Journal.merge_child_result(parent, child)

      assert merged.db == child_db
      assert merged.db != parent_db
      assert merged.accessed_addresses == MapSet.new([0xAA])
      assert merged.accessed_storage_keys == MapSet.new([{0xAA, 0x01}])
      assert merged.created_addresses == MapSet.new([0xCAFE])
      assert merged.touched_addresses == MapSet.new([0xCAFE])
    end

    test "appends child's logs after parent's, preserving emission order" do
      parent_log = %{address: 0xAA, topics: [1], data: <<>>}
      child_log_1 = %{address: 0xBB, topics: [2], data: <<>>}
      child_log_2 = %{address: 0xCC, topics: [3], data: <<>>}

      parent = %{parent_state() | logs: [parent_log]}
      child = %{parent | status: :stopped, logs: [child_log_1, child_log_2]}

      merged = Journal.merge_child_result(parent, child)

      assert merged.logs == [parent_log, child_log_1, child_log_2]
    end
  end

  describe "merge_child_result/2 — failed child" do
    for status <- [:reverted, :out_of_gas, :invalid, {:error, :stack_underflow}] do
      test "with status #{inspect(status)} keeps the parent's revertible fields" do
        parent = parent_state()

        child_db = InMemory.new() |> seed_account(0xCAFE, 100)

        child = %{
          parent
          | status: unquote(Macro.escape(status)),
            db: child_db,
            logs: [%{address: 0xBB, topics: [], data: <<>>}],
            accessed_addresses: MapSet.new([0xAA]),
            accessed_storage_keys: MapSet.new([{0xAA, 0x01}]),
            created_addresses: MapSet.new([0xCAFE]),
            touched_addresses: MapSet.new([0xCAFE])
        }

        merged = Journal.merge_child_result(parent, child)

        assert merged.db == parent.db
        assert merged.logs == parent.logs
        assert merged.accessed_addresses == parent.accessed_addresses
        assert merged.accessed_storage_keys == parent.accessed_storage_keys
        assert merged.created_addresses == parent.created_addresses
        assert merged.touched_addresses == parent.touched_addresses
      end
    end
  end

  describe "merge_child_result/2 — tracer propagation" do
    test "child's tracer is adopted on success" do
      parent = %{parent_state() | tracer: :parent_tracer}
      child = %{parent | status: :stopped, tracer: :child_tracer}

      assert Journal.merge_child_result(parent, child).tracer == :child_tracer
    end

    test "child's tracer is adopted on failure (tracing accumulates monotonically)" do
      parent = %{parent_state() | tracer: :parent_tracer}
      child = %{parent | status: :reverted, tracer: :child_tracer}

      assert Journal.merge_child_result(parent, child).tracer == :child_tracer
    end
  end

  describe "merge_child_result/2 — non-revertible fields" do
    test "parent's stack, memory, pc, gas, refund, contract are not touched on success" do
      parent = parent_state()
      child = %{parent | status: :stopped, pc: 999, gas: 999_999, refund: 555}

      merged = Journal.merge_child_result(parent, child)

      assert merged.pc == parent.pc
      assert merged.gas == parent.gas
      assert merged.refund == parent.refund
      assert merged.stack == parent.stack
      assert merged.memory == parent.memory
      assert merged.contract == parent.contract
    end
  end

  defp parent_state do
    MachineState.new(<<>>,
      db: InMemory.new(),
      accessed_addresses: MapSet.new(),
      accessed_storage_keys: MapSet.new(),
      created_addresses: MapSet.new(),
      touched_addresses: MapSet.new()
    )
  end

  defp seed_account(db, address, balance) do
    EEVM.Database.set_balance(db, address, balance)
  end
end
