defmodule Devx.RunBytecodeTest do
  use ExUnit.Case, async: true

  test "adds two numbers and returns the sum as a word" do
    # Yellow Paper gas: PUSH1 ×2 (3 each), ADD 3, PUSH1 3, MSTORE 3 plus one
    # word of memory (3·1 + 1²/512 = 3), PUSH1 ×2 (3 each), RETURN 0 = 24.
    assert Devx.RunBytecode.add(2, 3) == %{
             status: :success,
             sum: 5,
             return_data: "0x" <> String.duplicate("0", 63) <> "5",
             gas_used: 24,
             gas_left: 100_000 - 24
           }
  end

  test "runs hex bytecode and shows the stack, top first" do
    # PUSH1 10, PUSH1 20, ADD, PUSH1 1, STOP
    assert Devx.RunBytecode.stack("0x600a601401600100") == {:success, [1, 30]}
  end

  test "disassembles hex bytecode" do
    assert Devx.RunBytecode.disassemble("0x6001600201") ==
             [{0, "PUSH1", "0x01"}, {2, "PUSH1", "0x02"}, {4, "ADD", nil}]
  end
end
