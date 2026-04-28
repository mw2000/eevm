defmodule EEVM.Interpreter.Instructions.BlobTest do
  use ExUnit.Case, async: true

  alias EEVM.Context.{Block, Transaction}
  alias EEVM.Gas.Static

  describe "BLOBHASH (0x49) - EIP-4844" do
    test "returns versioned hash at valid index" do
      tx = Transaction.new(blob_hashes: [0xAABB, 0xCCDD, 0xEEFF])
      code = <<0x60, 0x00, 0x49, 0x00>>
      result = EEVM.execute(code, tx: tx)
      assert EEVM.stack_values(result) == [0xAABB]
    end

    test "returns hash at index 1" do
      tx = Transaction.new(blob_hashes: [0xAABB, 0xCCDD, 0xEEFF])
      code = <<0x60, 0x01, 0x49, 0x00>>
      result = EEVM.execute(code, tx: tx)
      assert EEVM.stack_values(result) == [0xCCDD]
    end

    test "returns 0 for out-of-range index" do
      tx = Transaction.new(blob_hashes: [0xAABB])
      code = <<0x60, 0x05, 0x49, 0x00>>
      result = EEVM.execute(code, tx: tx)
      assert EEVM.stack_values(result) == [0]
    end

    test "returns 0 with empty blob list" do
      code = <<0x60, 0x00, 0x49, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "costs 3 gas (very low)" do
      code = <<0x60, 0x00, 0x49, 0x00>>
      result = EEVM.execute(code, gas: 10_000)
      expected_cost = Static.static_cost(0x60) + Static.static_cost(0x49)
      assert result.gas == 10_000 - expected_cost
    end
  end

  describe "BLOBBASEFEE (0x4A) - EIP-7516" do
    test "returns block blob base fee" do
      block = Block.new(blob_base_fee: 1_000_000)
      code = <<0x4A, 0x00>>
      result = EEVM.execute(code, block: block)
      assert EEVM.stack_values(result) == [1_000_000]
    end

    test "returns 0 by default" do
      code = <<0x4A, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "costs 2 gas (base)" do
      code = <<0x4A, 0x00>>
      result = EEVM.execute(code, gas: 10_000)
      expected_cost = Static.static_cost(0x4A)
      assert result.gas == 10_000 - expected_cost
    end
  end
end
