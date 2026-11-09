defmodule EEVM.Interpreter.Instructions.GasRefundTest do
  use ExUnit.Case, async: true

  alias EEVM.Gas.Static
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.MachineState
  alias EEVM.Transaction.IntrinsicGas
  alias EEVM.TxEnv

  test "refund counter defaults to 0" do
    result = EEVM.Interpreter.run(<<0x00>>)

    assert result.status == :stopped
    assert result.frame.refund == 0
  end

  test "add_refund increments refund counter" do
    state = MachineState.new(<<0x00>>)
    updated = MachineState.add_refund(state, 15)

    assert updated.frame.refund == 15
  end

  test "sub_refund decrements and may go below 0" do
    state = MachineState.new(<<0x00>>, refund: 10)

    assert MachineState.sub_refund(state, 3).frame.refund == 7
    assert MachineState.sub_refund(state, 100).frame.refund == -90
  end

  test "refund is capped at gas_used/5" do
    code = <<0x60, 0x01, 0x50, 0x00>>
    initial_gas = 100
    refund_counter = 50

    result = EEVM.Interpreter.run(code, gas: initial_gas, refund: refund_counter)

    gas_used = Static.static_cost(0x60) + Static.static_cost(0x50) + Static.static_cost(0x00)
    effective_refund = min(refund_counter, div(gas_used, 5))
    expected_gas = initial_gas - gas_used + effective_refund

    assert result.status == :stopped
    assert result.frame.gas == expected_gas
    assert result.frame.refund == 0
  end

  test "Prague floors final charged gas after refunds to calldata floor cost" do
    tx = TxEnv.new(gas_limit: 22_000, to: 0xCAFE, data: <<0x00>>)
    initial_execution_gas = tx.gas_limit - IntrinsicGas.calculate(tx, HardforkConfig.new(:cancun))

    prague_result =
      EEVM.Interpreter.run(<<0x60, 0x01, 0x50, 0x00>>,
        gas: initial_execution_gas,
        tx: tx,
        hardfork: :prague,
        refund: 100
      )

    cancun_result =
      EEVM.Interpreter.run(<<0x60, 0x01, 0x50, 0x00>>,
        gas: initial_execution_gas,
        tx: tx,
        hardfork: :cancun,
        refund: 100
      )

    assert prague_result.status == :stopped
    assert prague_result.frame.refund == 0
    assert tx.gas_limit - prague_result.frame.gas == 21_010

    # 21_009 gas used including intrinsic gas, so the whole 100 refund fits
    # under the EIP-3529 cap of 21_009 / 5.
    assert cancun_result.status == :stopped
    assert tx.gas_limit - cancun_result.frame.gas == 20_909
  end

  test "Prague charges the calldata floor even when execution reverts" do
    # 100 non-zero bytes: intrinsic 21_000 + 100 * 16 = 22_600; EIP-7623 floor
    # 21_000 + 10 * (100 * 4 tokens) = 25_000.
    tx = TxEnv.new(gas_limit: 30_000, to: 0xCAFE, data: :binary.copy(<<0xFF>>, 100))

    result =
      EEVM.Interpreter.run(<<0x60, 0x00, 0x60, 0x00, 0xFD>>,
        gas: tx.gas_limit - IntrinsicGas.calculate(tx, HardforkConfig.new(:prague)),
        tx: tx,
        hardfork: :prague
      )

    assert result.status == :reverted
    assert tx.gas_limit - result.frame.gas == 25_000
  end

  test "top-level revert resets refund to 0" do
    result = EEVM.Interpreter.run(<<0x60, 0x00, 0x60, 0x00, 0xFD>>, refund: 25)

    assert result.status == :reverted
    assert result.frame.refund == 0
  end
end
