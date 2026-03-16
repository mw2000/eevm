defmodule EEVM.Opcodes.AccessListTest do
  use ExUnit.Case, async: true

  alias EEVM.WorldState
  alias EEVM.Context.Contract

  describe "EIP-2929 Access List Tracking" do
    test "first SLOAD is cold (2100 gas)" do
      code = <<0x60, 0x00, 0x54, 0x00>>
      result = EEVM.execute(code, gas: 10_000)
      assert result.gas == 10_000 - 3 - 2100
    end

    test "second SLOAD to same slot is warm (100 gas)" do
      code = <<0x60, 0x00, 0x54, 0x50, 0x60, 0x00, 0x54, 0x00>>
      result = EEVM.execute(code, gas: 10_000)
      assert result.gas == 10_000 - 3 - 2100 - 2 - 3 - 100
    end

    test "SLOAD on different slots are both cold" do
      code =
        IO.iodata_to_binary([
          <<0x60, 0x00, 0x54, 0x50>>,
          <<0x60, 0x01, 0x54, 0x50>>,
          <<0x00>>
        ])

      result = EEVM.execute(code, gas: 10_000)
      assert result.gas == 10_000 - (3 + 2100 + 2) - (3 + 2100 + 2)
    end

    test "BALANCE first access is cold (2600 gas)" do
      world_state = WorldState.new(%{0x42 => %{balance: 100}})
      code = <<0x60, 0x42, 0x31, 0x50, 0x00>>
      result = EEVM.execute(code, world_state: world_state, gas: 10_000)
      assert result.gas == 10_000 - 3 - 2600 - 2
    end

    test "BALANCE second access is warm (100 gas)" do
      world_state = WorldState.new(%{0x42 => %{balance: 100}})
      code = <<0x60, 0x42, 0x31, 0x50, 0x60, 0x42, 0x31, 0x50, 0x00>>
      result = EEVM.execute(code, world_state: world_state, gas: 10_000)
      assert result.gas == 10_000 - (3 + 2600 + 2) - (3 + 100 + 2)
    end

    test "pre-warmed addresses are warm from start" do
      contract = Contract.new(address: 0xAA)
      world_state = WorldState.new(%{0xAA => %{balance: 50}})
      code = <<0x60, 0xAA, 0x31, 0x50, 0x00>>
      result = EEVM.execute(code, world_state: world_state, contract: contract, gas: 10_000)
      assert result.gas == 10_000 - 3 - 100 - 2
    end

    test "precompile addresses are pre-warmed" do
      world_state = WorldState.new(%{0x01 => %{balance: 0}})
      code = <<0x60, 0x01, 0x31, 0x50, 0x00>>
      result = EEVM.execute(code, world_state: world_state, gas: 10_000)
      assert result.gas == 10_000 - 3 - 100 - 2
    end
  end
end
