defmodule EEVMTest do
  use ExUnit.Case
  import Bitwise
  doctest EEVM

  alias EEVM.{Stack, Memory, Storage, Gas}

  # ── Stack Tests ──────────────────────────────────────────────────────

  describe "Stack" do
    test "push and pop" do
      stack = Stack.new()
      {:ok, stack} = Stack.push(stack, 42)
      {:ok, stack} = Stack.push(stack, 99)
      {:ok, value, stack} = Stack.pop(stack)
      assert value == 99
      {:ok, value, _stack} = Stack.pop(stack)
      assert value == 42
    end

    test "underflow on empty pop" do
      assert {:error, :stack_underflow} = Stack.pop(Stack.new())
    end

    test "overflow at 1024" do
      stack =
        Enum.reduce(1..1024, Stack.new(), fn i, acc ->
          {:ok, s} = Stack.push(acc, i)
          s
        end)

      assert {:error, :stack_overflow} = Stack.push(stack, 1025)
    end

    test "values are masked to 256 bits" do
      too_big = 1 <<< 256
      {:ok, stack} = Stack.push(Stack.new(), too_big)
      {:ok, value, _} = Stack.pop(stack)
      # 2^256 wraps to 0
      assert value == 0
    end

    test "peek at depth" do
      {:ok, s} = Stack.push(Stack.new(), 10)
      {:ok, s} = Stack.push(s, 20)
      {:ok, s} = Stack.push(s, 30)

      assert {:ok, 30} = Stack.peek(s, 0)
      assert {:ok, 20} = Stack.peek(s, 1)
      assert {:ok, 10} = Stack.peek(s, 2)
      assert {:error, :stack_underflow} = Stack.peek(s, 3)
    end

    test "swap" do
      {:ok, s} = Stack.push(Stack.new(), 10)
      {:ok, s} = Stack.push(s, 20)
      {:ok, s} = Stack.push(s, 30)

      {:ok, swapped} = Stack.swap(s, 2)
      assert Stack.to_list(swapped) == [10, 20, 30]
    end
  end

  # ── Memory Tests ─────────────────────────────────────────────────────

  describe "Memory" do
    test "store and load word" do
      mem = Memory.new()
      mem = Memory.store(mem, 0, 0xFF)

      {value, _mem} = Memory.load(mem, 0)
      assert value == 0xFF
    end

    test "store byte" do
      mem = Memory.new()
      mem = Memory.store_byte(mem, 0, 0xAB)
      mem = Memory.store_byte(mem, 1, 0xCD)

      {value, _mem} = Memory.load(mem, 0)
      # First two bytes are 0xAB, 0xCD, rest are zeros
      assert value == 0xABCD000000000000000000000000000000000000000000000000000000000000
    end

    test "memory expands in 32-byte chunks" do
      mem = Memory.new()
      assert Memory.size(mem) == 0

      mem = Memory.store_byte(mem, 0, 1)
      assert Memory.size(mem) == 32

      mem = Memory.store_byte(mem, 33, 1)
      assert Memory.size(mem) == 64
    end

    test "uninitialized memory reads as zero" do
      mem = Memory.new()
      {value, _mem} = Memory.load(mem, 0)
      assert value == 0
    end
  end

  # ── Executor Tests ───────────────────────────────────────────────────

  describe "Executor - Arithmetic" do
    test "PUSH1 + ADD" do
      # PUSH1 2, PUSH1 3, ADD, STOP
      code = <<0x60, 2, 0x60, 3, 0x01, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [5]
    end

    test "PUSH1 + MUL" do
      # PUSH1 7, PUSH1 6, MUL, STOP
      code = <<0x60, 7, 0x60, 6, 0x02, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [42]
    end

    test "PUSH1 + SUB" do
      # PUSH1 3, PUSH1 10, SUB, STOP  → 10 - 3 = 7
      code = <<0x60, 3, 0x60, 10, 0x03, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [7]
    end

    test "SUB underflow wraps to uint256" do
      # PUSH1 10, PUSH1 3, SUB, STOP  → 3 - 10 = -7 wraps to 2^256 - 7
      code = <<0x60, 10, 0x60, 3, 0x03, 0x00>>
      result = EEVM.execute(code)
      max = (1 <<< 256) - 1
      assert EEVM.stack_values(result) == [max - 6]
    end

    test "DIV" do
      # PUSH1 2, PUSH1 10, DIV, STOP  → 10 / 2 = 5
      code = <<0x60, 2, 0x60, 10, 0x04, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [5]
    end

    test "DIV by zero returns 0" do
      # PUSH1 0, PUSH1 10, DIV, STOP  → 10 / 0 = 0
      code = <<0x60, 0, 0x60, 10, 0x04, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "MOD" do
      # PUSH1 3, PUSH1 10, MOD, STOP  → 10 % 3 = 1
      code = <<0x60, 3, 0x60, 10, 0x06, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "EXP" do
      # PUSH1 3, PUSH1 2, EXP, STOP → 2^3 = 8
      code = <<0x60, 3, 0x60, 2, 0x0A, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [8]
    end
  end

  describe "Executor - Comparison & Bitwise" do
    test "LT" do
      # PUSH1 5, PUSH1 3, LT, STOP  → 3 < 5 = 1 (true)
      code = <<0x60, 5, 0x60, 3, 0x10, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "GT" do
      # PUSH1 3, PUSH1 5, GT, STOP  → 5 > 3 = 1 (true)
      code = <<0x60, 3, 0x60, 5, 0x11, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "EQ true" do
      # PUSH1 42, PUSH1 42, EQ, STOP
      code = <<0x60, 42, 0x60, 42, 0x14, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "EQ false" do
      # PUSH1 1, PUSH1 2, EQ, STOP
      code = <<0x60, 1, 0x60, 2, 0x14, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "ISZERO" do
      # PUSH1 0, ISZERO, STOP  → 1
      code = <<0x60, 0, 0x15, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "AND, OR, XOR" do
      # PUSH1 0x0F, PUSH1 0xFF, AND, STOP → 0x0F
      code = <<0x60, 0x0F, 0x60, 0xFF, 0x16, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0x0F]
    end

    test "NOT" do
      # PUSH1 0, NOT, STOP → 2^256 - 1 (all ones)
      code = <<0x60, 0, 0x19, 0x00>>
      result = EEVM.execute(code)
      max = (1 <<< 256) - 1
      assert EEVM.stack_values(result) == [max]
    end
  end

  describe "Executor - Stack Operations" do
    test "POP" do
      # PUSH1 1, PUSH1 2, POP, STOP  → [1]
      code = <<0x60, 1, 0x60, 2, 0x50, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "DUP1" do
      # PUSH1 42, DUP1, STOP  → [42, 42]
      code = <<0x60, 42, 0x80, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [42, 42]
    end

    test "DUP2" do
      # PUSH1 1, PUSH1 2, DUP2, STOP  → [1, 2, 1]
      code = <<0x60, 1, 0x60, 2, 0x81, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1, 2, 1]
    end

    test "SWAP1" do
      # PUSH1 1, PUSH1 2, SWAP1, STOP  → [1, 2]
      code = <<0x60, 1, 0x60, 2, 0x90, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1, 2]
    end

    test "PUSH2 (multi-byte push)" do
      # PUSH2 0x0100, STOP  → 256
      code = <<0x61, 0x01, 0x00, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [256]
    end
  end

  describe "Executor - Memory" do
    test "MSTORE and MLOAD" do
      # PUSH1 0xFF, PUSH1 0, MSTORE, PUSH1 0, MLOAD, STOP
      code = <<0x60, 0xFF, 0x60, 0, 0x52, 0x60, 0, 0x51, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0xFF]
    end

    test "MSIZE" do
      # PUSH1 1, PUSH1 0, MSTORE, MSIZE, STOP
      code = <<0x60, 1, 0x60, 0, 0x52, 0x59, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [32]
    end
  end

  describe "Executor - Control Flow" do
    test "JUMP to JUMPDEST" do
      # PUSH1 4, JUMP, INVALID, JUMPDEST, PUSH1 42, STOP
      # PC:  0     2    3       4         5       7
      code = <<0x60, 4, 0x56, 0xFE, 0x5B, 0x60, 42, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [42]
    end

    test "JUMPI taken" do
      # PUSH1 1, PUSH1 6, JUMPI, INVALID, INVALID, INVALID, JUMPDEST, PUSH1 99, STOP
      code = <<0x60, 1, 0x60, 6, 0x57, 0xFE, 0x5B, 0x60, 99, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [99]
    end

    test "JUMPI not taken" do
      # PUSH1 0, PUSH1 8, JUMPI, PUSH1 42, STOP
      code = <<0x60, 0, 0x60, 8, 0x57, 0x60, 42, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [42]
    end
  end

  describe "Executor - Return & Halt" do
    test "RETURN returns data from memory" do
      # PUSH1 0xAB, PUSH1 0, MSTORE8, PUSH1 1, PUSH1 0, RETURN
      code = <<0x60, 0xAB, 0x60, 0, 0x53, 0x60, 1, 0x60, 0, 0xF3>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert result.return_data == <<0xAB>>
    end

    test "REVERT halts with :reverted" do
      # PUSH1 0, PUSH1 0, REVERT
      code = <<0x60, 0, 0x60, 0, 0xFD>>
      result = EEVM.execute(code)
      assert result.status == :reverted
    end

    test "INVALID halts with :invalid" do
      code = <<0xFE>>
      result = EEVM.execute(code)
      assert result.status == :invalid
    end

    test "implicit STOP at end of code" do
      # PUSH1 5 (no explicit STOP)
      code = <<0x60, 5>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [5]
    end
  end

  describe "Disassembler" do
    test "disassembles simple program" do
      code = <<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>
      result = EEVM.disassemble(code)

      assert result == [
               {0, "PUSH1", "0x01"},
               {2, "PUSH1", "0x02"},
               {4, "ADD", nil},
               {5, "STOP", nil}
             ]
    end
  end

  # ── Gas Metering Tests ────────────────────────────────────────────────

  describe "Gas Metering" do
    test "gas is consumed by arithmetic opcodes" do
      # PUSH1 2, PUSH1 3, ADD, STOP
      # Gas costs: PUSH1=3, PUSH1=3, ADD=3, STOP=0 → total = 9
      code = <<0x60, 2, 0x60, 3, 0x01, 0x00>>
      result = EEVM.execute(code, gas: 1_000_000)
      assert result.status == :stopped
      assert result.gas == 1_000_000 - 9
    end

    test "out of gas halts execution" do
      # PUSH1 1, PUSH1 2, ADD, STOP — needs 9 gas, give it 5
      code = <<0x60, 1, 0x60, 2, 0x01, 0x00>>
      result = EEVM.execute(code, gas: 5)
      assert result.status == :out_of_gas
    end

    test "exact gas is sufficient" do
      # PUSH1 1, STOP — needs exactly 3 gas
      code = <<0x60, 1, 0x00>>
      result = EEVM.execute(code, gas: 3)
      assert result.status == :stopped
      assert result.gas == 0
    end

    test "one gas short causes out_of_gas" do
      # PUSH1 1, STOP — needs 3 gas, give 2
      code = <<0x60, 1, 0x00>>
      result = EEVM.execute(code, gas: 2)
      assert result.status == :out_of_gas
    end

    test "MUL costs 5 gas" do
      # PUSH1 2, PUSH1 3, MUL, STOP → 3+3+5+0 = 11
      code = <<0x60, 2, 0x60, 3, 0x02, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 11
    end

    test "DIV costs 5 gas" do
      # PUSH1 2, PUSH1 10, DIV, STOP → 3+3+5+0 = 11
      code = <<0x60, 2, 0x60, 10, 0x04, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 11
    end

    test "comparison opcodes cost 3 gas" do
      # PUSH1 1, PUSH1 2, LT, STOP → 3+3+3+0 = 9
      code = <<0x60, 1, 0x60, 2, 0x10, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 9
    end

    test "INVALID consumes all remaining gas" do
      code = <<0xFE>>
      result = EEVM.execute(code, gas: 5000)
      assert result.status == :invalid
      assert result.gas == 0
    end

    test "EXP dynamic gas charges per byte of exponent" do
      # PUSH1 0xFF, PUSH1 2, EXP, STOP
      # Static: PUSH1=3 + PUSH1=3 + EXP=10 + STOP=0
      # Dynamic: exponent 0xFF is 1 byte → 50 * 1 = 50
      # Total: 16 + 50 = 66
      code = <<0x60, 0xFF, 0x60, 2, 0x0A, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.status == :stopped
      assert result.gas == 1000 - 66
    end

    test "EXP with zero exponent has no dynamic gas" do
      # PUSH1 0, PUSH1 2, EXP, STOP
      # Static: 3+3+10+0 = 16, Dynamic: 0 bytes → 0
      code = <<0x60, 0, 0x60, 2, 0x0A, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.status == :stopped
      assert result.gas == 1000 - 16
    end

    test "EXP with 2-byte exponent charges 100 dynamic gas" do
      # PUSH2 0x0100 (=256, 2 bytes), PUSH1 2, EXP, STOP
      # Static: 3+3+10+0 = 16, Dynamic: 2 bytes → 100
      code = <<0x61, 0x01, 0x00, 0x60, 2, 0x0A, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.status == :stopped
      assert result.gas == 1000 - 116
    end

    test "memory expansion gas for MSTORE" do
      # PUSH1 0xFF, PUSH1 0, MSTORE, STOP
      # PUSH1=3 + PUSH1=3 + MSTORE=3 + mem_expansion(0→32) + STOP=0
      # Memory expansion: 0→1 word = 3*1 + 1^2/512 = 3
      code = <<0x60, 0xFF, 0x60, 0, 0x52, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.status == :stopped
      expected_gas = 3 + 3 + 3 + Gas.memory_expansion_cost_word(0, 0) + 0
      assert result.gas == 1000 - expected_gas
    end

    test "memory expansion gas grows with offset" do
      # Store at offset 1024 — expands 0→1056 bytes (33 words)
      # PUSH1 1, PUSH2 0x0400, MSTORE, STOP
      code = <<0x60, 1, 0x61, 0x04, 0x00, 0x52, 0x00>>
      result = EEVM.execute(code, gas: 100_000)
      assert result.status == :stopped
      # Memory expanded from 0 to cover offset 1024+32 = 1056 → 33 words
      mem_cost = Gas.memory_expansion_cost_word(0, 1024)
      expected_gas = 3 + 3 + 3 + mem_cost + 0
      assert result.gas == 100_000 - expected_gas
    end

    test "second memory access to same region costs no expansion" do
      # MSTORE at 0, then MLOAD at 0 — second op has no expansion
      # PUSH1 1, PUSH1 0, MSTORE, PUSH1 0, MLOAD, STOP
      code = <<0x60, 1, 0x60, 0, 0x52, 0x60, 0, 0x51, 0x00>>
      result = EEVM.execute(code, gas: 100_000)
      assert result.status == :stopped

      # First MSTORE: 3(push)+3(push)+3(mstore)+3(mem 0→32)+3(push)+3(mload)+0(mem, already 32)+0(stop)
      mem_cost1 = Gas.memory_expansion_cost_word(0, 0)
      mem_cost2 = Gas.memory_expansion_cost_word(32, 0)
      expected = 3 + 3 + 3 + mem_cost1 + 3 + 3 + mem_cost2 + 0
      assert result.gas == 100_000 - expected
    end

    test "POP costs 2 gas" do
      # PUSH1 1, POP, STOP → 3+2+0 = 5
      code = <<0x60, 1, 0x50, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 5
    end

    test "JUMP costs 8 gas" do
      # PUSH1 3, JUMP, JUMPDEST, STOP
      code = <<0x60, 3, 0x56, 0x5B, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      # PUSH1=3, JUMP=8, JUMPDEST=1, STOP=0 → 12
      assert result.gas == 1000 - 12
    end
  end

  # ── Storage Tests ──────────────────────────────────────────────────

  describe "Storage (SLOAD/SSTORE)" do
    test "SSTORE then SLOAD retrieves the stored value" do
      # PUSH1 42, PUSH1 0, SSTORE, PUSH1 0, SLOAD, STOP
      code = <<0x60, 42, 0x60, 0, 0x55, 0x60, 0, 0x54, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [42]
    end

    test "SLOAD of uninitialized slot returns 0" do
      # PUSH1 99, SLOAD, STOP
      code = <<0x60, 99, 0x54, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "SSTORE overwrites previous value" do
      # Store 10 at slot 0, then store 20 at slot 0, then load slot 0
      code =
        <<0x60, 10, 0x60, 0, 0x55>> <>
          <<0x60, 20, 0x60, 0, 0x55>> <>
          <<0x60, 0, 0x54, 0x00>>

      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [20]
    end

    test "SSTORE and SLOAD with different slots" do
      # Store 111 at slot 0, store 222 at slot 1, load slot 0, load slot 1
      code =
        <<0x60, 111, 0x60, 0, 0x55>> <>
          <<0x60, 222, 0x60, 1, 0x55>> <>
          <<0x60, 0, 0x54>> <>
          <<0x60, 1, 0x54, 0x00>>

      result = EEVM.execute(code)
      # Stack: [slot1_val, slot0_val] (top first)
      assert EEVM.stack_values(result) == [222, 111]
    end

    test "SLOAD with pre-loaded storage" do
      # Pre-load slot 5 with value 9999, then SLOAD it
      storage = Storage.new(%{5 => 9999})
      code = <<0x60, 5, 0x54, 0x00>>
      result = EEVM.execute(code, storage: storage)
      assert EEVM.stack_values(result) == [9999]
    end

    test "SSTORE gas cost is 20000" do
      # PUSH1 1, PUSH1 0, SSTORE, STOP
      # Gas: PUSH1=3 + PUSH1=3 + SSTORE=20000 + STOP=0 = 20006
      code = <<0x60, 1, 0x60, 0, 0x55, 0x00>>
      result = EEVM.execute(code, gas: 100_000)
      assert result.gas == 100_000 - 20_006
    end

    test "SLOAD gas cost is 200" do
      # PUSH1 0, SLOAD, STOP
      # Gas: PUSH1=3 + SLOAD=200 + STOP=0 = 203
      code = <<0x60, 0, 0x54, 0x00>>
      result = EEVM.execute(code, gas: 1_000)
      assert result.gas == 1_000 - 203
    end

    test "SSTORE out of gas" do
      # SSTORE costs 20000 — give only 100
      code = <<0x60, 1, 0x60, 0, 0x55, 0x00>>
      result = EEVM.execute(code, gas: 100)
      assert result.status == :out_of_gas
    end

    test "storage persists across multiple SLOAD calls" do
      # Store 7 at slot 3, load slot 3 twice
      code =
        <<0x60, 7, 0x60, 3, 0x55>> <>
          <<0x60, 3, 0x54>> <>
          <<0x60, 3, 0x54, 0x00>>

      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [7, 7]
    end

    test "storage is in final machine state" do
      # Store 42 at slot 0
      code = <<0x60, 42, 0x60, 0, 0x55, 0x00>>
      result = EEVM.execute(code)
      assert Storage.load(result.storage, 0) == 42
    end
  end
end
