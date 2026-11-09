defmodule EEVM.Interpreter.Instructions.AccessListTest do
  use ExUnit.Case, async: true

  alias EEVM.Context.Contract
  alias EEVM.WorldState

  describe "EIP-2929 Access List Tracking" do
    test "first SLOAD is cold (2100 gas)" do
      code = <<0x60, 0x00, 0x54, 0x00>>
      result = EEVM.execute(code, gas: 10_000)
      assert result.frame.gas == 10_000 - 3 - 2100
    end

    test "second SLOAD to same slot is warm (100 gas)" do
      code = <<0x60, 0x00, 0x54, 0x50, 0x60, 0x00, 0x54, 0x00>>
      result = EEVM.execute(code, gas: 10_000)
      assert result.frame.gas == 10_000 - 3 - 2100 - 2 - 3 - 100
    end

    test "SLOAD on different slots are both cold" do
      code =
        IO.iodata_to_binary([
          <<0x60, 0x00, 0x54, 0x50>>,
          <<0x60, 0x01, 0x54, 0x50>>,
          <<0x00>>
        ])

      result = EEVM.execute(code, gas: 10_000)
      assert result.frame.gas == 10_000 - (3 + 2100 + 2) - (3 + 2100 + 2)
    end

    test "BALANCE first access is cold (2600 gas)" do
      world_state = WorldState.new(%{0x42 => %{balance: 100}})
      code = <<0x60, 0x42, 0x31, 0x50, 0x00>>
      result = EEVM.execute(code, world_state: world_state, gas: 10_000)
      assert result.frame.gas == 10_000 - 3 - 2600 - 2
    end

    test "BALANCE second access is warm (100 gas)" do
      world_state = WorldState.new(%{0x42 => %{balance: 100}})
      code = <<0x60, 0x42, 0x31, 0x50, 0x60, 0x42, 0x31, 0x50, 0x00>>
      result = EEVM.execute(code, world_state: world_state, gas: 10_000)
      assert result.frame.gas == 10_000 - (3 + 2600 + 2) - (3 + 100 + 2)
    end

    test "pre-warmed addresses are warm from start" do
      contract = Contract.new(address: 0xAA)
      world_state = WorldState.new(%{0xAA => %{balance: 50}})
      code = <<0x60, 0xAA, 0x31, 0x50, 0x00>>
      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 10_000)
      assert result.frame.gas == 10_000 - 3 - 100 - 2
    end

    test "CALL-family opcodes charge 2600 for a cold target and 100 once warm" do
      world_state = WorldState.new(%{0x42 => %{code: <<0x00>>}})

      for opcode <- [0xF1, 0xF2, 0xF4, 0xFA] do
        value = if opcode in [0xF1, 0xF2], do: <<0x60, 0x00>>, else: <<>>
        # retSize retOffset argsSize argsOffset [value] address gas, then CALL* and POP
        call =
          <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00>> <>
            value <> <<0x60, 0x42, 0x60, 0x00, opcode, 0x50>>

        pushes = if opcode in [0xF1, 0xF2], do: 7, else: 6

        result = EEVM.execute(call <> call <> <<0x00>>, world_state: world_state, gas: 100_000)

        # EIP-2929: first access 2,600 (static 100 + 2,500 surcharge), second 100.
        assert result.frame.gas == 100_000 - 2 * (pushes * 3 + 2) - 2_600 - 100
      end
    end

    test "CALL-family opcodes at the depth limit still charge cold access and memory" do
      world_state = WorldState.new(%{0x42 => %{code: <<0x00>>}})

      for opcode <- [0xF1, 0xF2, 0xF4, 0xFA] do
        value = if opcode in [0xF1, 0xF2], do: <<0x60, 0x00>>, else: <<>>
        # retSize=32 retOffset argsSize argsOffset [value] address gas, then CALL*
        call =
          <<0x60, 0x20, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00>> <>
            value <> <<0x60, 0x42, 0x61, 0xFF, 0xFF, opcode, 0x00>>

        pushes = if opcode in [0xF1, 0xF2], do: 7, else: 6

        result = EEVM.execute(call, world_state: world_state, gas: 100_000, depth: 1024)

        assert result.frame.stack.elements == [0]
        assert MapSet.member?(result.substate.accessed_addresses, 0x42)
        # Cold access (2,600) and one word of memory (3) are charged; the
        # forwarded gas comes back because no frame is entered.
        assert result.frame.gas == 100_000 - pushes * 3 - 2_600 - 3
      end
    end

    test "CALL-family opcodes pay only their flat static price before Berlin" do
      for opcode <- [0xF1, 0xF2, 0xF4, 0xFA] do
        value = if opcode in [0xF1, 0xF2], do: <<0x60, 0x00>>, else: <<>>

        call =
          <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00>> <>
            value <> <<0x60, 0x42, 0x60, 0x00, opcode, 0x50>>

        pushes = if opcode in [0xF1, 0xF2], do: 7, else: 6

        result = EEVM.execute(call <> call <> <<0x00>>, gas: 100_000, hardfork: :istanbul)

        # EIP-150 price, no warm/cold distinction.
        assert result.frame.gas == 100_000 - 2 * (pushes * 3 + 2) - 700 - 700
      end
    end

    test "precompile addresses are pre-warmed" do
      world_state = WorldState.new(%{0x01 => %{balance: 0}})
      code = <<0x60, 0x01, 0x31, 0x50, 0x00>>
      result = EEVM.execute(code, world_state: world_state, gas: 10_000)
      assert result.frame.gas == 10_000 - 3 - 100 - 2
    end
  end
end
