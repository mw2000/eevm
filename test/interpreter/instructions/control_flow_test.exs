defmodule EEVM.Interpreter.Instructions.ControlFlowTest do
  use ExUnit.Case, async: true
  import EEVM.TestSupport.MachineHelpers

  doctest EEVM.Interpreter.Instructions.Helpers
  doctest EEVM.Interpreter.InstructionTable

  describe "Executor - Stack Operations" do
    test "POP" do
      # PUSH1 1, PUSH1 2, POP, STOP  → [1]
      code = <<0x60, 1, 0x60, 2, 0x50, 0x00>>
      result = run_code(code)
      assert stack_values(result) == [1]
    end

    test "DUP1" do
      # PUSH1 42, DUP1, STOP  → [42, 42]
      code = <<0x60, 42, 0x80, 0x00>>
      result = run_code(code)
      assert stack_values(result) == [42, 42]
    end

    test "DUP2" do
      # PUSH1 1, PUSH1 2, DUP2, STOP  → [1, 2, 1]
      code = <<0x60, 1, 0x60, 2, 0x81, 0x00>>
      result = run_code(code)
      assert stack_values(result) == [1, 2, 1]
    end

    test "SWAP1" do
      # PUSH1 1, PUSH1 2, SWAP1, STOP  → [1, 2]
      code = <<0x60, 1, 0x60, 2, 0x90, 0x00>>
      result = run_code(code)
      assert stack_values(result) == [1, 2]
    end

    test "PUSH2 (multi-byte push)" do
      # PUSH2 0x0100, STOP  → 256
      code = <<0x61, 0x01, 0x00, 0x00>>
      result = run_code(code)
      assert stack_values(result) == [256]
    end
  end

  # Code runs undecoded until its frame has used enough gas, then decoded
  # (#210); each tier checks jumps its own way, so both run every case.
  for tier <- [:undecoded, :decoded] do
    describe "Executor - Control Flow, #{tier}" do
      @tier tier

      test "JUMP to JUMPDEST" do
        # PUSH1 4, JUMP, INVALID, JUMPDEST, PUSH1 42, STOP
        # PC:  0     2    3       4         5       7
        code = <<0x60, 4, 0x56, 0xFE, 0x5B, 0x60, 42, 0x00>>
        result = run(@tier, code)
        assert result.status == :stopped
        assert stack_values(result) == [42]
      end

      test "JUMPI taken" do
        # PUSH1 1, PUSH1 6, JUMPI, INVALID, INVALID, INVALID, JUMPDEST, PUSH1 99, STOP
        code = <<0x60, 1, 0x60, 6, 0x57, 0xFE, 0x5B, 0x60, 99, 0x00>>
        result = run(@tier, code)
        assert result.status == :stopped
        assert stack_values(result) == [99]
      end

      # Yellow Paper §9.4.3: a 0x5B byte inside PUSH data is not a JUMPDEST
      # (ethereum/tests vmIOandFlowOperations/jumpToPush).
      test "JUMP and JUMPI into PUSH data halt with an invalid jump destination" do
        # PUSH1 4, JUMP, PUSH1 0x5B, STOP: byte 4 is 0x5B but PUSH1's immediate
        jump = <<0x60, 4, 0x56, 0x60, 0x5B, 0x00>>
        # PUSH1 1, PUSH1 6, JUMPI, PUSH1 0x5B, STOP
        jumpi = <<0x60, 1, 0x60, 6, 0x57, 0x60, 0x5B, 0x00>>

        for code <- [jump, jumpi] do
          result = run(@tier, code, gas: 1000)
          assert result.status == {:error, :invalid_jump_destination}
          assert result.frame.gas == 0
        end
      end

      test "a JUMPDEST right after PUSH32 data is valid" do
        # PUSH1 36, JUMP, PUSH32 (0x5B x 32), JUMPDEST (pc 36), PUSH1 7, STOP
        code = <<0x60, 36, 0x56, 0x7F>> <> :binary.copy(<<0x5B>>, 32) <> <<0x5B, 0x60, 7, 0x00>>
        result = run(@tier, code)
        assert result.status == :stopped
        assert stack_values(result) == [7]
      end

      test "JUMPI not taken" do
        # PUSH1 0, PUSH1 8, JUMPI, PUSH1 42, STOP
        code = <<0x60, 0, 0x60, 8, 0x57, 0x60, 42, 0x00>>
        result = run(@tier, code)
        assert stack_values(result) == [42]
      end

      # The interpreter runs PUSH+JUMPI to a JUMPDEST as one instruction (#208);
      # it must charge and fall through exactly like the two opcodes.
      test "JUMPI to a valid JUMPDEST, not taken, falls through after the JUMPI" do
        # PUSH1 0, PUSH1 8, JUMPI, PUSH1 42, STOP, JUMPDEST (pc 8), PUSH1 7, STOP
        code = <<0x60, 0, 0x60, 8, 0x57, 0x60, 42, 0x00, 0x5B, 0x60, 7, 0x00>>
        result = run(@tier, code, gas: 1000)
        assert stack_values(result) == [42]
        # PUSH1 + PUSH1 + JUMPI + PUSH1 (Yellow Paper Appendix G)
        assert result.frame.gas == 1000 - (3 + 3 + 10 + 3)
      end

      # Yellow Paper §9.4.2 checks each opcode on its own: with 1024 items and
      # gas for the PUSH but not the JUMP, the PUSH overflows the stack; with
      # gas for neither, the PUSH runs out of gas.
      test "PUSH+JUMP fails at the PUSH like the two opcodes would" do
        # 1024 x PUSH0, PUSH2 1028, JUMP, JUMPDEST (pc 1028), STOP
        code = :binary.copy(<<0x5F>>, 1024) <> <<0x61, 1028::16, 0x56, 0x5B, 0x00>>
        push0_gas = 1024 * 2

        assert run(@tier, code, gas: push0_gas + 5).status == {:error, :stack_overflow}
        assert run(@tier, code, gas: push0_gas + 2).status == :out_of_gas
      end

      # With gas for the PUSH but not the jump, the PUSH runs and the jump runs
      # out of gas (it once reported a stack overflow).
      test "PUSH+JUMP(I) with gas for the PUSH alone runs out of gas at the jump" do
        # PUSH1 4, JUMP, INVALID, JUMPDEST, STOP
        jump = <<0x60, 4, 0x56, 0xFE, 0x5B, 0x00>>
        # PUSH1 1, PUSH1 6, JUMPI, INVALID, JUMPDEST (pc 6), STOP
        jumpi = <<0x60, 1, 0x60, 6, 0x57, 0xFE, 0x5B, 0x00>>

        # PUSH1 = 3, JUMP = 8, JUMPI = 10, JUMPDEST = 1 (Yellow Paper Appendix G)
        assert run(@tier, jump, gas: 3 + 7).status == :out_of_gas
        assert run(@tier, jumpi, gas: 3 + 3 + 9).status == :out_of_gas
        assert run(@tier, jumpi, gas: 3 + 3 + 10 + 1).status == :stopped
      end
    end
  end

  # A frame runs large code undecoded and decodes it at a jump once it has
  # used about 3 gas per code byte (#210): for 24 KB of code at the top level,
  # after about 53,000 gas, here in the loop's 2,000th iteration or so. The
  # loop must go on from the same pc, gas, and stack, now through the fused
  # PUSH1+JUMPI.
  test "a loop that decodes its code part-way through runs on unchanged" do
    # PUSH2 3000, JUMPDEST (pc 3), PUSH1 1, SWAP1, SUB, DUP1, PUSH1 3, JUMPI, STOP,
    # then STOPs up to 24 KB
    loop = <<0x61, 3000::16, 0x5B, 0x60, 1, 0x90, 0x03, 0x80, 0x60, 3, 0x57, 0x00>>
    code = loop <> :binary.copy(<<0x00>>, 24_576 - byte_size(loop))
    result = run_code(code, gas: 100_000)

    assert result.status == :stopped
    assert stack_values(result) == [0]
    # PUSH2, then 3,000 x (JUMPDEST + PUSH1 + SWAP1 + SUB + DUP1 + PUSH1 + JUMPI)
    assert result.frame.gas == 100_000 - (3 + 3000 * (1 + 3 + 3 + 3 + 3 + 3 + 10))
    # 24 KB of code starts undecoded, so it decoded part-way through.
    refute match?({:undecoded, _, _}, result.frame.program)
  end

  defp run(tier, code, opts \\ [])
  defp run(:undecoded, code, opts), do: run_undecoded(code, opts)
  defp run(:decoded, code, opts), do: run_decoded(code, opts)

  describe "PUSH0 (EIP-3855)" do
    test "pushes 0 onto the stack" do
      # PUSH0, STOP
      code = <<0x5F, 0x00>>
      result = run_code(code)
      assert stack_values(result) == [0]
    end

    test "pushing a 1025th item halts with stack overflow and burns all gas" do
      result = run_code(:binary.copy(<<0x5F>>, 1025), gas: 10_000)

      assert result.status == {:error, :stack_overflow}
      assert result.frame.gas == 0
    end

    test "PUSH0 costs 2 gas (base)" do
      code = <<0x5F, 0x00>>
      result = run_code(code, gas: 1000)
      assert result.frame.gas == 1000 - 2
    end

    test "PUSH0 + PUSH0 + ADD = 0" do
      # PUSH0, PUSH0, ADD, STOP
      code = <<0x5F, 0x5F, 0x01, 0x00>>
      result = run_code(code)
      assert stack_values(result) == [0]
    end

    test "PUSH0 is cheaper than PUSH1 0" do
      # PUSH0 costs 2, PUSH1 costs 3
      push0_code = <<0x5F, 0x00>>
      push1_code = <<0x60, 0, 0x00>>
      r0 = run_code(push0_code, gas: 1000)
      r1 = run_code(push1_code, gas: 1000)
      assert r0.frame.gas > r1.frame.gas
    end

    test "disassembles as PUSH0" do
      [{0, name, nil}] = EEVM.disassemble(<<0x5F>>)
      assert name == "PUSH0"
    end
  end
end
