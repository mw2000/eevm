defmodule EEVM.Opcodes.GasRefundTest do
  use ExUnit.Case, async: true

  alias EEVM.{CallFrame, Executor, MachineState, Memory, Stack}
  alias EEVM.Context.Contract
  alias EEVM.Gas.Static
  alias EEVM.Context.Transaction
  alias EEVM.Transaction.IntrinsicGas

  test "refund counter defaults to 0" do
    result = EEVM.execute(<<0x00>>)

    assert result.status == :stopped
    assert result.refund == 0
  end

  test "add_refund increments refund counter" do
    state = MachineState.new(<<0x00>>)
    updated = MachineState.add_refund(state, 15)

    assert updated.refund == 15
  end

  test "sub_refund decrements with floor at 0" do
    state = MachineState.new(<<0x00>>, refund: 10)

    assert MachineState.sub_refund(state, 3).refund == 7
    assert MachineState.sub_refund(state, 100).refund == 0
  end

  test "refund is capped at gas_used/5" do
    code = <<0x60, 0x01, 0x50, 0x00>>
    initial_gas = 100
    refund_counter = 50

    result = EEVM.execute(code, gas: initial_gas, refund: refund_counter)

    gas_used = Static.static_cost(0x60) + Static.static_cost(0x50) + Static.static_cost(0x00)
    effective_refund = min(refund_counter, div(gas_used, 5))
    expected_gas = initial_gas - gas_used + effective_refund

    assert result.status == :stopped
    assert result.gas == expected_gas
    assert result.refund == 0
  end

  test "Prague floors final charged gas after refunds to calldata floor cost" do
    tx = Transaction.new(gas_limit: 22_000, to: 0xCAFE, data: <<0x00>>)
    initial_execution_gas = tx.gas_limit - IntrinsicGas.calculate(tx)

    prague_result =
      EEVM.execute(<<0x60, 0x01, 0x50, 0x00>>,
        gas: initial_execution_gas,
        tx: tx,
        hardfork: :prague,
        refund: 100
      )

    cancun_result =
      EEVM.execute(<<0x60, 0x01, 0x50, 0x00>>,
        gas: initial_execution_gas,
        tx: tx,
        hardfork: :cancun,
        refund: 100
      )

    assert prague_result.status == :stopped
    assert prague_result.refund == 0
    assert tx.gas_limit - prague_result.gas == 21_010

    assert cancun_result.status == :stopped
    assert tx.gas_limit - cancun_result.gas == 21_008
  end

  test "top-level revert resets refund to 0" do
    result = EEVM.execute(<<0x60, 0x00, 0x60, 0x00, 0xFD>>, refund: 25)

    assert result.status == :reverted
    assert result.refund == 0
  end

  test "nested call success preserves accumulated refund" do
    parent_state =
      MachineState.new(<<0x00>>, contract: Contract.new(address: 1), gas: 1_000, refund: 7)

    child_frame = %CallFrame{
      code: <<0x00>>,
      pc: 0,
      stack: Stack.new(),
      memory: Memory.new(),
      gas: 100,
      contract: Contract.new(address: 2, caller: 1),
      return_offset: 0,
      return_size: 0,
      is_static: false,
      depth: 1
    }

    {:ok, state_after_push} = MachineState.push_frame(parent_state, child_frame)
    child_halted = %{state_after_push | status: :stopped, refund: 12}

    result = Executor.run_loop(child_halted)

    assert result.status == :stopped
    assert result.call_stack == []
    assert result.refund == 12
  end

  test "nested call revert restores parent refund snapshot" do
    parent_state =
      MachineState.new(<<0x00>>, contract: Contract.new(address: 1), gas: 1_000, refund: 7)

    child_frame = %CallFrame{
      code: <<0xFD>>,
      pc: 0,
      stack: Stack.new(),
      memory: Memory.new(),
      gas: 100,
      contract: Contract.new(address: 2, caller: 1),
      return_offset: 0,
      return_size: 0,
      is_static: false,
      depth: 1
    }

    {:ok, state_after_push} = MachineState.push_frame(parent_state, child_frame)
    child_reverted = %{state_after_push | status: :reverted, refund: 12}

    result = Executor.run_loop(child_reverted)

    assert result.status == :stopped
    assert result.call_stack == []
    assert result.refund == 7
  end
end
