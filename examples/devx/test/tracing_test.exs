defmodule Devx.TracingTest do
  use ExUnit.Case, async: true

  alias Devx.{Erc20, Tracing}

  @alice 0xA11CE
  @bob 0xB0B

  # PUSH1 5, PUSH1 0, SSTORE, PUSH1 1, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, KECCAK256, STOP
  @straight_line <<0x60, 5, 0x60, 0, 0x55, 0x60, 1, 0x60, 0, 0x52, 0x60, 0x20, 0x60, 0, 0x20,
                   0x00>>

  # Solidity stores mapping entry `key` of the mapping in `slot` at
  # keccak256(key . slot); balanceOf is the token's slot 1, after `name`.
  defp balance_slot(owner), do: :binary.decode_unsigned(EEVM.keccak256(<<owner::256, 1::256>>))

  setup do
    {:ok, token, db, _logs} = Erc20.deploy(EEVM.Database.InMemory.new(), @alice, 1_000)
    {trace, _gas_used} = Tracing.transfer(db, token, @alice, @bob, 5)
    %{trace: trace}
  end

  test "records every opcode with its pc and the stack before it, top first", %{trace: trace} do
    # solc's prologue: PUSH1 0x80, PUSH1 0x40, MSTORE.
    assert [{0, :PUSH1, []}, {2, :PUSH1, [0x80]}, {4, :MSTORE, [0x40, 0x80]} | _] =
             Tracing.steps(trace)

    assert {_pc, :RETURN, _stack} = List.last(Tracing.steps(trace))
  end

  test "shows the storage writes of a transfer", %{trace: trace} do
    assert Tracing.storage_writes(trace) == [{balance_slot(@alice), 995}, {balance_slot(@bob), 5}]
  end

  test "renders EIP-3155 JSON: depth from 1 and the stack bottom first", %{trace: trace} do
    [first, second, third | _] = trace |> Tracing.json_lines() |> Enum.map(&Jason.decode!/1)

    assert %{"pc" => 0, "op" => 0x60, "opName" => "PUSH1", "depth" => 1, "stack" => []} = first
    assert %{"pc" => 2, "stack" => ["0x80"]} = second
    assert %{"opName" => "MSTORE", "stack" => ["0x80", "0x40"]} = third
  end

  test "gas used by straight-line code" do
    # PUSH1 ×2 6, SSTORE of a cold, unset slot 20,000 + 2,100 (EIP-2929),
    # PUSH1 ×2 6, MSTORE 3 + 3 memory, PUSH1 ×2 6, KECCAK256 30 + 6 per word.
    assert {_trace, 22_160} = Tracing.run(@straight_line)
  end

  test "step costs add up to the gas used" do
    {trace, gas_used} = Tracing.run(@straight_line)
    assert Tracing.total_step_cost(trace) == gas_used
  end
end
