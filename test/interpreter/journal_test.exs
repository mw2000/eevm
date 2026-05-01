defmodule EEVM.Interpreter.JournalTest do
  use ExUnit.Case, async: true

  alias EEVM.Database.InMemory
  alias EEVM.Interpreter.{Journal, MachineState}

  describe "merge_child_result/2 — successful child" do
    test "promotes child's revertible fields onto the parent" do
      parent = parent_state()
      parent_db = parent.db

      child_db = InMemory.new() |> seed_account(0xCAFE, 100)

      child_substate = %{
        parent.substate
        | accessed_addresses: MapSet.new([0xAA]),
          accessed_storage_keys: MapSet.new([{0xAA, 0x01}]),
          created_addresses: MapSet.new([0xCAFE]),
          touched_addresses: MapSet.new([0xCAFE])
      }

      child = %{parent | status: :stopped, db: child_db, substate: child_substate}

      merged = Journal.merge_child_result(parent, child)

      assert merged.db == child_db
      assert merged.db != parent_db
      assert merged.substate.accessed_addresses == MapSet.new([0xAA])
      assert merged.substate.accessed_storage_keys == MapSet.new([{0xAA, 0x01}])
      assert merged.substate.created_addresses == MapSet.new([0xCAFE])
      assert merged.substate.touched_addresses == MapSet.new([0xCAFE])
    end

    test "appends child's logs after parent's, preserving emission order" do
      parent_log = %{address: 0xAA, topics: [1], data: <<>>}
      child_log_1 = %{address: 0xBB, topics: [2], data: <<>>}
      child_log_2 = %{address: 0xCC, topics: [3], data: <<>>}

      base = parent_state()
      parent = %{base | substate: %{base.substate | logs: [parent_log]}}

      child = %{
        parent
        | status: :stopped,
          substate: %{parent.substate | logs: [child_log_1, child_log_2]}
      }

      merged = Journal.merge_child_result(parent, child)

      assert merged.substate.logs == [parent_log, child_log_1, child_log_2]
    end
  end

  describe "merge_child_result/2 — failed child" do
    for status <- [:reverted, :out_of_gas, :invalid, {:error, :stack_underflow}] do
      test "with status #{inspect(status)} keeps the parent's revertible fields" do
        parent = parent_state()

        child_db = InMemory.new() |> seed_account(0xCAFE, 100)

        child_substate = %{
          parent.substate
          | logs: [%{address: 0xBB, topics: [], data: <<>>}],
            accessed_addresses: MapSet.new([0xAA]),
            accessed_storage_keys: MapSet.new([{0xAA, 0x01}]),
            created_addresses: MapSet.new([0xCAFE]),
            touched_addresses: MapSet.new([0xCAFE])
        }

        child = %{
          parent
          | status: unquote(Macro.escape(status)),
            db: child_db,
            substate: child_substate
        }

        merged = Journal.merge_child_result(parent, child)

        assert merged.db == parent.db
        assert merged.substate.logs == parent.substate.logs
        assert merged.substate.accessed_addresses == parent.substate.accessed_addresses
        assert merged.substate.accessed_storage_keys == parent.substate.accessed_storage_keys
        assert merged.substate.created_addresses == parent.substate.created_addresses
        assert merged.substate.touched_addresses == parent.substate.touched_addresses
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
