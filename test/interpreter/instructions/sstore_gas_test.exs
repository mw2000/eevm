defmodule EEVM.Interpreter.Instructions.SstoreGasTest do
  use ExUnit.Case, async: true
  import EEVM.TestSupport.MachineHelpers

  alias EEVM.Context.Contract
  alias EEVM.Database.InMemory
  alias EEVM.Tracer

  describe "SSTORE gas schedule (EIP-2200 + EIP-3529)" do
    test "no-op SSTORE (current == new) costs 100 gas on warm slot" do
      code = <<0x60, 0x07, 0x60, 0x00, 0x55, 0x00>>

      result =
        EEVM.Interpreter.run(code,
          gas: 10_000,
          db: InMemory.new(storage: %{0 => %{0 => 7}}),
          accessed_storage_keys: MapSet.new([{0, 0}])
        )

      assert result.frame.gas == 10_000 - 3 - 3 - 100
      assert result.frame.refund == 0
    end

    test "fresh write (0 -> nonzero) on clean slot costs 20_000" do
      code = <<0x60, 0x01, 0x60, 0x00, 0x55, 0x00>>

      result =
        EEVM.Interpreter.run(code,
          gas: 30_000,
          accessed_storage_keys: MapSet.new([{0, 0}])
        )

      assert result.frame.gas == 30_000 - 3 - 3 - 20_000
      assert result.frame.refund == 0
    end

    test "clean update (nonzero -> different nonzero) costs 2_900" do
      code = <<0x60, 0x09, 0x60, 0x00, 0x55, 0x00>>

      result =
        EEVM.Interpreter.run(code,
          gas: 10_000,
          db: InMemory.new(storage: %{0 => %{0 => 7}}),
          accessed_storage_keys: MapSet.new([{0, 0}])
        )

      assert result.frame.gas == 10_000 - 3 - 3 - 2_900
      assert result.frame.refund == 0
    end

    test "clean clear (nonzero -> 0) costs 2_900 and adds 4_800 refund" do
      code = <<0x60, 0x00, 0x60, 0x00, 0x55, 0x00>>
      initial_gas = 10_000

      result =
        EEVM.Interpreter.run(code,
          gas: initial_gas,
          db: InMemory.new(storage: %{0 => %{0 => 7}}),
          accessed_storage_keys: MapSet.new([{0, 0}])
        )

      # gas_used = 3 + 3 + 2900 = 2906, refund = 4800, effective = min(4800, 2906/5) = 581
      gas_used = 3 + 3 + 2_900
      effective_refund = min(4_800, div(gas_used, 5))
      assert result.frame.gas == initial_gas - gas_used + effective_refund
      assert result.frame.refund == 0
    end

    test "dirty slot rewrite costs 100" do
      code =
        <<0x60, 0x07, 0x60, 0x00, 0x55>> <>
          <<0x60, 0x09, 0x60, 0x00, 0x55, 0x00>>

      result =
        EEVM.Interpreter.run(code,
          gas: 20_000,
          db: InMemory.new(storage: %{0 => %{0 => 5}})
        )

      assert result.frame.gas == 20_000 - (3 + 3 + 2_100 + 2_900) - (3 + 3 + 100)
      assert result.frame.refund == 0
    end

    test "dirty slot reset to original nonzero adds 2_800 refund" do
      code = <<0x60, 0x05, 0x60, 0x00, 0x55, 0x00>>
      initial_gas = 10_000

      result =
        EEVM.Interpreter.run(code,
          gas: initial_gas,
          db: InMemory.new(storage: %{0 => %{0 => 7}}),
          original_storage: %{{0, 0} => 5},
          accessed_storage_keys: MapSet.new([{0, 0}])
        )

      # gas_used = 3 + 3 + 100 = 106, refund = 2800, effective = min(2800, 106/5) = 21
      gas_used = 3 + 3 + 100
      effective_refund = min(2_800, div(gas_used, 5))
      assert result.frame.gas == initial_gas - gas_used + effective_refund
      assert result.frame.refund == 0
    end

    test "dirty slot reset to original zero adds 19_900 refund" do
      code = <<0x60, 0x00, 0x60, 0x00, 0x55, 0x00>>
      initial_gas = 30_000

      result =
        EEVM.Interpreter.run(code,
          gas: initial_gas,
          db: InMemory.new(storage: %{0 => %{0 => 7}}),
          original_storage: %{{0, 0} => 0},
          accessed_storage_keys: MapSet.new([{0, 0}])
        )

      # gas_used = 3 + 3 + 100 = 106, refund = 19900, effective = min(19900, 106/5) = 21
      gas_used = 3 + 3 + 100
      effective_refund = min(19_900, div(gas_used, 5))
      assert result.frame.gas == initial_gas - gas_used + effective_refund
      assert result.frame.refund == 0
    end

    test "cold slot access adds 2_100 surcharge" do
      code = <<0x60, 0x07, 0x60, 0x00, 0x55, 0x00>>

      result =
        EEVM.Interpreter.run(code, gas: 10_000, db: InMemory.new(storage: %{0 => %{0 => 7}}))

      assert result.frame.gas == 10_000 - 3 - 3 - 2_100 - 100
      assert result.frame.refund == 0
    end

    test "warm second access has no extra surcharge" do
      code =
        <<0x60, 0x07, 0x60, 0x00, 0x55>> <>
          <<0x60, 0x07, 0x60, 0x00, 0x55, 0x00>>

      result =
        EEVM.Interpreter.run(code, gas: 10_000, db: InMemory.new(storage: %{0 => %{0 => 7}}))

      assert result.frame.gas == 10_000 - (3 + 3 + 2_100 + 100) - (3 + 3 + 100)
      assert result.frame.refund == 0
    end
  end

  describe "SSTORE original value across call frames" do
    test "a child frame prices a slot against its value at transaction start" do
      # Slot 1 starts at 2. The top frame clears it, then CALLs itself; the
      # child (CALLER == ADDRESS) jumps to 0x15 and writes 3. Original 2,
      # current 0, new 3 is a dirty write: 100 gas on the warm slot, not the
      # 20_000 of a fresh 0 -> 3 write.
      code =
        Base.decode16!("3330146015576000600155600080808080305AF1005B600360015500")

      db =
        InMemory.new(
          accounts: %{0xA => %{balance: 0, nonce: 0, code: code}},
          storage: %{0xA => %{1 => 2}}
        )

      {state, tracer} =
        trace_code(code, db: db, contract: Contract.new(address: 0xA, caller: 0xCA11E2))

      assert state.status == :stopped
      assert sstore_costs_at_depth(tracer, 1) == [100]
    end

    test "originals are tracked per contract, not per slot number" do
      # A writes its own slot 0 (0 -> 1), then CALLs B, whose slot 0 holds 5.
      # B's write 5 -> 6 is a clean reset on a cold slot: 2_100 + 2_900.
      b_code = <<0x60, 0x06, 0x60, 0x00, 0x55, 0x00>>

      a_code =
        <<0x60, 0x01, 0x60, 0x00, 0x55>> <>
          :binary.copy(<<0x60, 0x00>>, 5) <> <<0x60, 0xBB, 0x5A, 0xF1, 0x00>>

      db =
        InMemory.new(
          accounts: %{
            0xA => %{balance: 0, nonce: 0, code: a_code},
            0xBB => %{balance: 0, nonce: 0, code: b_code}
          },
          storage: %{0xBB => %{0 => 5}}
        )

      {state, tracer} =
        trace_code(a_code, db: db, contract: Contract.new(address: 0xA, caller: 0xCA11E2))

      assert state.status == :stopped
      assert sstore_costs_at_depth(tracer, 1) == [5_000]
    end
  end

  # Gas charged by each SSTORE at `depth`: the drop in remaining gas between
  # the SSTORE step and the step after it.
  defp sstore_costs_at_depth(tracer, depth) do
    tracer
    |> Tracer.steps()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [step, _next] -> step.op == :SSTORE and step.depth == depth end)
    |> Enum.map(fn [step, next] -> step.gas_remaining - next.gas_remaining end)
  end

  describe "SSTORE gas schedule by hardfork" do
    # Gas used by `PUSH1 value, PUSH1 0, SSTORE` against slot 0 holding 7,
    # minus the two pushes. Refunds are not involved (no slot is cleared).
    defp sstore_gas(value, fork, gas \\ 100_000) do
      code = <<0x60, value, 0x60, 0x00, 0x55, 0x00>>

      result =
        EEVM.Interpreter.run(code,
          gas: gas,
          hardfork: fork,
          db: InMemory.new(storage: %{0 => %{0 => 7}})
        )

      {result.status, gas - result.frame.gas - 6}
    end

    test "before Istanbul every non-set write costs 5,000, even a no-op" do
      assert sstore_gas(7, :byzantium) == {:stopped, 5_000}
      assert sstore_gas(9, :byzantium) == {:stopped, 5_000}
      # ConstantinopleFix (Petersburg) dropped EIP-1283 net metering.
      assert sstore_gas(7, :constantinople) == {:stopped, 5_000}
    end

    test "Istanbul (EIP-2200) prices a no-op write at SLOAD_GAS, 800" do
      assert sstore_gas(7, :istanbul) == {:stopped, 800}
      assert sstore_gas(9, :istanbul) == {:stopped, 5_000}
    end

    test "Berlin (EIP-2929) prices a cold no-op at 2,100 + 100 and a cold update at 5,000" do
      assert sstore_gas(7, :berlin) == {:stopped, 2_100 + 100}
      assert sstore_gas(9, :berlin) == {:stopped, 2_100 + 2_900}
    end

    test "Istanbul onward, SSTORE needs more than the 2,300 stipend left (EIP-2200 sentry)" do
      assert {:out_of_gas, _} = sstore_gas(7, :istanbul, 6 + 2_300)
      assert sstore_gas(7, :istanbul, 6 + 2_301) == {:stopped, 800}
      assert {:out_of_gas, _} = sstore_gas(7, :berlin, 6 + 2_300)
    end
  end
end
