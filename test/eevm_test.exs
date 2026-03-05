defmodule EEVMTest do
  use ExUnit.Case
  import Bitwise
  doctest EEVM

  alias EEVM.{Stack, Memory, Storage, ExecutionContext, Gas}

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

  # ── Environment Opcode Tests ─────────────────────────────────────────

  describe "Environment Opcodes" do
    test "ADDRESS pushes current contract address" do
      ctx = ExecutionContext.new(address: 0xCAFE)
      # ADDRESS, STOP
      code = <<0x30, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [0xCAFE]
    end

    test "CALLER pushes msg.sender" do
      ctx = ExecutionContext.new(caller: 0xDEAD)
      code = <<0x33, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [0xDEAD]
    end

    test "ORIGIN pushes tx.origin" do
      ctx = ExecutionContext.new(origin: 0xBEEF)
      code = <<0x32, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [0xBEEF]
    end

    test "CALLVALUE pushes msg.value" do
      ctx = ExecutionContext.new(callvalue: 1_000_000)
      code = <<0x34, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [1_000_000]
    end

    test "CALLDATASIZE pushes length of calldata" do
      ctx = ExecutionContext.new(calldata: <<1, 2, 3, 4>>)
      code = <<0x36, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [4]
    end

    test "CALLDATASIZE is 0 with no calldata" do
      code = <<0x36, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "CALLDATALOAD reads 32 bytes from calldata" do
      # 32 bytes of calldata, load from offset 0
      calldata = <<0::248, 42>>
      ctx = ExecutionContext.new(calldata: calldata)
      # PUSH1 0, CALLDATALOAD, STOP
      code = <<0x60, 0, 0x35, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [42]
    end

    test "CALLDATALOAD pads with zeros past end" do
      # 4 bytes of calldata, load from offset 0 — pads 28 zeros on right
      calldata = <<0xFF, 0xFF, 0xFF, 0xFF>>
      ctx = ExecutionContext.new(calldata: calldata)
      code = <<0x60, 0, 0x35, 0x00>>
      result = EEVM.execute(code, context: ctx)
      expected = 0xFFFFFFFF00000000000000000000000000000000000000000000000000000000
      assert EEVM.stack_values(result) == [expected]
    end

    test "CALLDATALOAD beyond calldata returns 0" do
      ctx = ExecutionContext.new(calldata: <<1, 2>>)
      code = <<0x60, 100, 0x35, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [0]
    end

    test "CALLDATACOPY copies calldata to memory" do
      calldata = <<0xAA, 0xBB, 0xCC, 0xDD>>
      ctx = ExecutionContext.new(calldata: calldata)
      # PUSH1 4 (length), PUSH1 0 (data_offset), PUSH1 0 (dest_offset), CALLDATACOPY
      # PUSH1 0, MLOAD, STOP
      code = <<0x60, 4, 0x60, 0, 0x60, 0, 0x37, 0x60, 0, 0x51, 0x00>>
      result = EEVM.execute(code, context: ctx)
      # Memory word at 0: 0xAABBCCDD followed by 28 zero bytes
      expected = 0xAABBCCDD00000000000000000000000000000000000000000000000000000000
      assert EEVM.stack_values(result) == [expected]
    end

    test "CODESIZE pushes bytecode length" do
      # CODESIZE, STOP — 2 bytes of code
      code = <<0x38, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [2]
    end

    test "GASPRICE pushes tx gas price" do
      ctx = ExecutionContext.new(gasprice: 20_000_000_000)
      code = <<0x3A, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [20_000_000_000]
    end

    test "RETURNDATASIZE pushes 0 with no prior return" do
      code = <<0x3D, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "COINBASE pushes block producer address" do
      ctx = ExecutionContext.new(block_coinbase: 0xABC)
      code = <<0x41, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [0xABC]
    end

    test "TIMESTAMP pushes block timestamp" do
      ctx = ExecutionContext.new(block_timestamp: 1_700_000_000)
      code = <<0x42, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [1_700_000_000]
    end

    test "NUMBER pushes block number" do
      ctx = ExecutionContext.new(block_number: 18_000_000)
      code = <<0x43, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [18_000_000]
    end

    test "PREVRANDAO pushes previous block randao" do
      ctx = ExecutionContext.new(block_prevrandao: 0xDEADBEEF)
      code = <<0x44, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [0xDEADBEEF]
    end

    test "GASLIMIT pushes block gas limit" do
      ctx = ExecutionContext.new(block_gaslimit: 30_000_000)
      code = <<0x45, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [30_000_000]
    end

    test "CHAINID pushes chain ID (default 1 = mainnet)" do
      code = <<0x46, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [1]
    end

    test "CHAINID with custom chain ID" do
      ctx = ExecutionContext.new(block_chainid: 137)
      code = <<0x46, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [137]
    end

    test "BASEFEE pushes block base fee" do
      ctx = ExecutionContext.new(block_basefee: 30_000_000_000)
      code = <<0x48, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [30_000_000_000]
    end

    test "BALANCE looks up address balance" do
      ctx = ExecutionContext.new(balances: %{0xDEAD => 5_000_000})
      # PUSH2 0xDEAD, BALANCE, STOP
      code = <<0x61, 0xDE, 0xAD, 0x31, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [5_000_000]
    end

    test "BALANCE returns 0 for unknown address" do
      code = <<0x61, 0xDE, 0xAD, 0x31, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "SELFBALANCE pushes own contract balance" do
      ctx = ExecutionContext.new(address: 0xCAFE, balances: %{0xCAFE => 999})
      code = <<0x47, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [999]
    end

    test "BLOCKHASH returns hash for recent block" do
      ctx =
        ExecutionContext.new(
          block_number: 100,
          block_hashes: %{99 => 0xAAAA, 98 => 0xBBBB}
        )

      # PUSH1 99, BLOCKHASH, STOP
      code = <<0x60, 99, 0x40, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [0xAAAA]
    end

    test "BLOCKHASH returns 0 for current or future block" do
      ctx = ExecutionContext.new(block_number: 100)
      # PUSH1 100, BLOCKHASH, STOP (current block → 0)
      code = <<0x60, 100, 0x40, 0x00>>
      result = EEVM.execute(code, context: ctx)
      assert EEVM.stack_values(result) == [0]
    end

    test "GAS pushes remaining gas after deducting for GAS opcode" do
      # GAS (0x5A), STOP
      # GAS costs 2 gas, STOP costs 0
      # So after GAS executes, gas_remaining = initial - 2
      # The value pushed should be gas AFTER the GAS opcode's cost
      code = <<0x5A, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      # GAS pushes remaining gas (1000-2=998), then STOP costs 0
      assert EEVM.stack_values(result) == [998]
      assert result.gas == 998
    end

    test "env opcodes have correct gas costs" do
      # ADDRESS costs 2 (base)
      code = <<0x30, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 2
    end

    test "BALANCE costs 2600 gas" do
      code = <<0x60, 0, 0x31, 0x00>>
      result = EEVM.execute(code, gas: 10_000)
      # PUSH1=3 + BALANCE=2600 + STOP=0 = 2603
      assert result.gas == 10_000 - 2603
    end

    test "SELFBALANCE costs 5 gas" do
      code = <<0x47, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 5
    end
  end

  # ── PUSH0 & KECCAK256 Tests ────────────────────────────────────────

  describe "PUSH0 (EIP-3855)" do
    test "pushes 0 onto the stack" do
      # PUSH0, STOP
      code = <<0x5F, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "PUSH0 costs 2 gas (base)" do
      code = <<0x5F, 0x00>>
      result = EEVM.execute(code, gas: 1000)
      assert result.gas == 1000 - 2
    end

    test "PUSH0 + PUSH0 + ADD = 0" do
      # PUSH0, PUSH0, ADD, STOP
      code = <<0x5F, 0x5F, 0x01, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0]
    end

    test "PUSH0 is cheaper than PUSH1 0" do
      # PUSH0 costs 2, PUSH1 costs 3
      push0_code = <<0x5F, 0x00>>
      push1_code = <<0x60, 0, 0x00>>
      r0 = EEVM.execute(push0_code, gas: 1000)
      r1 = EEVM.execute(push1_code, gas: 1000)
      assert r0.gas > r1.gas
    end

    test "disassembles as PUSH0" do
      [{0, name, nil}] = EEVM.disassemble(<<0x5F>>)
      assert name == "PUSH0"
    end
  end

  describe "KECCAK256" do
    test "hashes empty data" do
      # PUSH1 0 (length), PUSH1 0 (offset), KECCAK256, STOP
      code = <<0x60, 0, 0x60, 0, 0x20, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      # Keccak-256 of empty data
      expected = ExKeccak.hash_256(<<>>)
      <<expected_int::unsigned-big-256>> = expected
      assert EEVM.stack_values(result) == [expected_int]
    end

    test "hashes data stored in memory" do
      # Store 0xFF at memory[0], then hash the first byte
      # PUSH1 0xFF, PUSH1 0, MSTORE8, PUSH1 1 (length), PUSH1 0 (offset), KECCAK256, STOP
      code = <<0x60, 0xFF, 0x60, 0, 0x53, 0x60, 1, 0x60, 0, 0x20, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      expected = ExKeccak.hash_256(<<0xFF>>)
      <<expected_int::unsigned-big-256>> = expected
      assert EEVM.stack_values(result) == [expected_int]
    end

    test "static gas is 30 + dynamic 6 per word" do
      # Hash 32 bytes (1 word): PUSH1 32, PUSH1 0, KECCAK256, STOP
      # Static (charged in run_loop): 30
      # Dynamic: 6 * 1 word = 6
      # Memory expansion: 0→32 bytes = 3 gas
      # Other: PUSH1=3 + PUSH1=3 + STOP=0
      code = <<0x60, 32, 0x60, 0, 0x20, 0x00>>
      result = EEVM.execute(code, gas: 10_000)
      # Total: 3 + 3 + 30 + 6 + 3 + 0 = 45
      assert result.gas == 10_000 - 45
    end

    test "dynamic gas scales with data size" do
      # Hash 64 bytes (2 words) vs 32 bytes (1 word)
      # Extra word costs 6 more gas
      code1 = <<0x60, 32, 0x60, 0, 0x20, 0x00>>
      code2 = <<0x60, 64, 0x60, 0, 0x20, 0x00>>
      r1 = EEVM.execute(code1, gas: 100_000)
      r2 = EEVM.execute(code2, gas: 100_000)
      # r2 should use 6 more gas (1 extra word) + some memory expansion
      assert r1.gas > r2.gas
    end

    test "out of gas on large hash" do
      # Try to hash 1024 bytes with only 100 gas
      code = <<0x61, 0x04, 0x00, 0x60, 0, 0x20, 0x00>>
      result = EEVM.execute(code, gas: 100)
      assert result.status == :out_of_gas
    end

    test "disassembles as KECCAK256" do
      [{0, name, nil}] = EEVM.disassemble(<<0x20>>)
      assert name == "KECCAK256"
    end
  end
end
