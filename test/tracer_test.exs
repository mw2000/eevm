defmodule EEVM.TracerTest do
  use ExUnit.Case, async: true

  alias EEVM.Tracer
  alias EEVM.Tracer.TraceStep

  describe "opt-in behavior" do
    test "tracer is nil by default — no trace recorded" do
      state = EEVM.execute(<<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>)
      assert state.tracer == nil
    end

    test "trace/2 attaches a fresh tracer and records every opcode" do
      # PUSH1 1, PUSH1 2, ADD, STOP
      {state, tracer} = EEVM.trace(<<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>)
      assert state.status == :stopped

      steps = Tracer.steps(tracer)
      assert length(steps) == 4
      assert Enum.map(steps, & &1.op) == [:PUSH1, :PUSH1, :ADD, :STOP]
      assert Enum.map(steps, & &1.pc) == [0, 2, 4, 5]
    end
  end

  describe "per-step fields" do
    # PUSH1 0x0A, PUSH1 0x14, ADD, STOP
    setup do
      {_state, tracer} = EEVM.trace(<<0x60, 0x0A, 0x60, 0x14, 0x01, 0x00>>)
      {:ok, steps: Tracer.steps(tracer)}
    end

    test "pre-step gas is recorded before static cost is deducted", %{steps: steps} do
      [push1_a, push1_b, add, stop] = steps
      # Each PUSH costs 3 gas, ADD costs 3 gas, STOP costs 0. Initial gas = 1_000_000.
      assert push1_a.gas_remaining == 1_000_000
      assert push1_a.gas_cost == 3

      assert push1_b.gas_remaining == 999_997
      assert push1_b.gas_cost == 3

      assert add.gas_remaining == 999_994
      assert add.gas_cost == 3

      assert stop.gas_remaining == 999_991
      assert stop.gas_cost == 0
    end

    test "pre-step stack snapshot is what the opcode reads (top first)", %{steps: steps} do
      [push1_a, push1_b, add, _stop] = steps
      assert push1_a.stack == []
      assert push1_b.stack == [0x0A]
      # ADD pops the top two elements; before execution the stack has [0x14, 0x0A] top-first.
      assert add.stack == [0x14, 0x0A]
    end

    test "depth is 0 for top-level execution", %{steps: steps} do
      assert Enum.all?(steps, &(&1.depth == 0))
    end

    test "op_byte and op name agree with the bytecode", %{steps: steps} do
      [push1_a, _, add, stop] = steps
      assert push1_a.op == :PUSH1
      assert push1_a.op_byte == 0x60
      assert add.op == :ADD
      assert add.op_byte == 0x01
      assert stop.op == :STOP
      assert stop.op_byte == 0x00
    end
  end

  describe "error capture" do
    test "out-of-gas terminates with an error step" do
      # ADD with empty stack consumes static cost, then errors on pop.
      # Too little gas even for the static cost:
      {_state, tracer} = EEVM.trace(<<0x01>>, gas: 2)
      steps = Tracer.steps(tracer)
      assert [%TraceStep{op: :ADD, error: :out_of_gas}] = steps
    end

    test "stack underflow reports the underlying reason" do
      {state, tracer} = EEVM.trace(<<0x01>>)
      assert match?({:error, :stack_underflow}, state.status)
      [step] = Tracer.steps(tracer)
      assert step.op == :ADD
      assert step.error == :stack_underflow
    end
  end

  describe "nested calls track depth" do
    test "STATICCALL into a contract bumps depth in the child's trace" do
      alias EEVM.Context.Contract
      alias EEVM.Database.InMemory, as: DB

      callee_code = <<0x60, 0x42, 0x00>>
      callee_addr = 0xC0FFEE

      db =
        DB.new()
        |> EEVM.Database.put_code(callee_addr, callee_code)

      # STATICCALL gas addr argsOffset argsSize retOffset retSize
      # push args in reverse: 0, 0, 0, 0, addr, 0xFFFF
      caller_code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x62, 0xC0, 0xFF, 0xEE, 0x61, 0xFF,
          0xFF, 0xFA, 0x00>>

      {_state, tracer} =
        EEVM.trace(caller_code,
          db: db,
          contract: %{Contract.new() | address: 0xCA11E2}
        )

      steps = Tracer.steps(tracer)
      parent_ops = Enum.filter(steps, &(&1.depth == 0))
      child_ops = Enum.filter(steps, &(&1.depth == 1))

      assert Enum.any?(parent_ops, &(&1.op == :STATICCALL))
      assert Enum.map(child_ops, & &1.op) == [:PUSH1, :STOP]
    end
  end

  describe "JSON output (EIP-3155 / geth --json)" do
    test "each line is valid JSON with geth-compatible keys" do
      {_state, tracer} = EEVM.trace(<<0x60, 0x01, 0x00>>)
      [line1, line2] = Tracer.to_json_lines(tracer)

      decoded1 = Jason.decode!(line1)
      assert decoded1["op"] == 0x60
      assert decoded1["opName"] == "PUSH1"
      assert decoded1["pc"] == 0
      assert decoded1["depth"] == 1
      assert decoded1["stack"] == []
      assert decoded1["memSize"] == 0
      assert String.starts_with?(decoded1["gas"], "0x")
      assert String.starts_with?(decoded1["gasCost"], "0x")

      decoded2 = Jason.decode!(line2)
      assert decoded2["opName"] == "STOP"
      # After PUSH1, the stack has one element — encoded bottom-first, hex.
      assert decoded2["stack"] == ["0x1"]
    end

    test "to_json joins lines with newlines" do
      {_state, tracer} = EEVM.trace(<<0x60, 0x01, 0x00>>)
      rendered = Tracer.to_json(tracer)
      assert length(String.split(rendered, "\n")) == 2
    end

    test "error steps include an error field" do
      {_state, tracer} = EEVM.trace(<<0x01>>)
      [line] = Tracer.to_json_lines(tracer)
      assert Jason.decode!(line)["error"] == "stack_underflow"
    end
  end
end
