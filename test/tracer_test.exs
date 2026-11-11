defmodule EEVM.TracerTest do
  use ExUnit.Case, async: true
  import EEVM.TestSupport.MachineHelpers

  alias EEVM.Tracer
  alias EEVM.Tracer.TraceStep

  doctest Tracer

  describe "opt-in behavior" do
    test "tracer is nil by default — no trace recorded" do
      state = run_code(<<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>)
      assert state.tracer == nil
    end

    test "trace/2 attaches a fresh tracer and records every opcode" do
      # PUSH1 1, PUSH1 2, ADD, STOP
      {state, tracer} = trace_code(<<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>)
      assert state.status == :stopped

      steps = Tracer.steps(tracer)
      assert length(steps) == 4
      assert Enum.map(steps, & &1.op) == [:PUSH1, :PUSH1, :ADD, :STOP]
      assert Enum.map(steps, & &1.pc) == [0, 2, 4, 5]
    end
  end

  describe "per-step fields" do
    # PUSH1 0x0A, PUSH1 0x14, ADD, STOP
    setup do
      {_state, tracer} = trace_code(<<0x60, 0x0A, 0x60, 0x14, 0x01, 0x00>>)
      {:ok, steps: Tracer.steps(tracer)}
    end

    test "pre-step gas is recorded before static cost is deducted", %{steps: steps} do
      [push1_a, push1_b, add, stop] = steps
      # Each PUSH costs 3 gas, ADD costs 3 gas, STOP costs 0. Initial gas = 1_000_000.
      assert push1_a.gas_remaining == 1_000_000
      assert push1_a.gas_cost == 3

      assert push1_b.gas_remaining == 999_997
      assert push1_b.gas_cost == 3

      assert add.gas_remaining == 999_994
      assert add.gas_cost == 3

      assert stop.gas_remaining == 999_991
      assert stop.gas_cost == 0
    end

    test "pre-step stack snapshot is what the opcode reads (top first)", %{steps: steps} do
      [push1_a, push1_b, add, _stop] = steps
      assert push1_a.stack == []
      assert push1_b.stack == [0x0A]
      # ADD pops the top two elements; before execution the stack has [0x14, 0x0A] top-first.
      assert add.stack == [0x14, 0x0A]
    end

    test "depth is 0 for top-level execution", %{steps: steps} do
      assert Enum.all?(steps, &(&1.depth == 0))
    end

    test "op_byte and op name agree with the bytecode", %{steps: steps} do
      [push1_a, _, add, stop] = steps
      assert push1_a.op == :PUSH1
      assert push1_a.op_byte == 0x60
      assert add.op == :ADD
      assert add.op_byte == 0x01
      assert stop.op == :STOP
      assert stop.op_byte == 0x00
    end
  end

  describe "op_name/1" do
    # Mnemonics from the Yellow Paper, Appendix H, and EIP-3855 (PUSH0).
    test "names every opcode family, including both ends of the generated ranges" do
      assert Tracer.op_name(0x00) == :STOP
      assert Tracer.op_name(0x5F) == :PUSH0
      assert Tracer.op_name(0x60) == :PUSH1
      assert Tracer.op_name(0x7F) == :PUSH32
      assert Tracer.op_name(0x80) == :DUP1
      assert Tracer.op_name(0x8F) == :DUP16
      assert Tracer.op_name(0x90) == :SWAP1
      assert Tracer.op_name(0x9F) == :SWAP16
      assert Tracer.op_name(0xFE) == :INVALID
      assert Tracer.op_name(0xFF) == :SELFDESTRUCT
    end

    test "undefined bytes are :UNKNOWN" do
      assert Tracer.op_name(0x0C) == :UNKNOWN
      assert Tracer.op_name(0xEF) == :UNKNOWN
    end
  end

  describe "error capture" do
    test "out-of-gas terminates with an error step" do
      # ADD with empty stack consumes static cost, then errors on pop.
      # Too little gas even for the static cost:
      {_state, tracer} = trace_code(<<0x01>>, gas: 2)
      steps = Tracer.steps(tracer)
      assert [%TraceStep{op: :ADD, error: :out_of_gas}] = steps
    end

    test "stack underflow reports the underlying reason" do
      {state, tracer} = trace_code(<<0x01>>)
      assert match?({:error, :stack_underflow}, state.status)
      [step] = Tracer.steps(tracer)
      assert step.op == :ADD
      assert step.error == :stack_underflow
    end
  end

  describe "gas cost" do
    alias EEVM.BlockEnv
    alias EEVM.Crypto.{ECDSA, Keccak}
    alias EEVM.Database.InMemory
    alias EEVM.Transaction.{Legacy, Signer}

    @private_key <<0x46::256>>
    @block BlockEnv.new(gas_limit: 30_000_000, base_fee: 0, coinbase: 0xC0F0)

    test "counts dynamic gas: storage, memory expansion, and hashed words" do
      # The snippet from #213: PUSH1 5 PUSH1 0 SSTORE; PUSH1 1 PUSH1 0 MSTORE;
      # PUSH1 32 PUSH1 0 KECCAK256; STOP.
      code = <<0x60, 5, 0x60, 0, 0x55, 0x60, 1, 0x60, 0, 0x52, 0x60, 0x20, 0x60, 0, 0x20, 0x00>>
      {:ok, result} = EEVM.run(code, tracer: true)
      steps = Tracer.steps(result.trace)

      # EIP-2929 cold slot 2,100 + EIP-2200 set 20,000; MSTORE 3 + one new
      # memory word 3; KECCAK256 30 + 6 per word (Yellow Paper Appendix G).
      assert Enum.map(steps, &{&1.op, &1.gas_cost}) ==
               [PUSH1: 3, PUSH1: 3, SSTORE: 22_100, PUSH1: 3, PUSH1: 3, MSTORE: 6] ++
                 [PUSH1: 3, PUSH1: 3, KECCAK256: 36, STOP: 0]

      assert total_cost(steps) == result.gas_used
    end

    test "an ERC-20 transfer reconciles with intrinsic gas and the refund" do
      sender = address_of(@private_key)
      token = 0x70CE
      recipient = 0xB0B
      sender_slot = balance_slot(sender)

      # The whole balance moves, so the sender's slot is cleared.
      db =
        InMemory.new(
          accounts: %{sender => %{balance: 10 ** 18}, token => %{nonce: 1, code: erc20()}},
          storage: %{token => %{sender_slot => 1_000}}
        )

      data = <<0xA9059CBB::32, recipient::256, 1_000::256>>

      {:ok, result} =
        EEVM.transact(signed_tx(token, data), @block, db, hardfork: :cancun, tracer: true)

      assert result.status == :success
      steps = Tracer.steps(result.trace)

      # EIP-3529: clearing a slot set before the transaction refunds 4,800.
      assert total_cost(steps) + intrinsic_gas(data) - 4_800 == result.gas_used
      assert result.gas_used == 45_674
    end

    test "CALL counts the gas it forwards, and a nested call reconciles" do
      callee = 0xB
      # Callee: SSTORE 1 into a fresh slot, then RETURN nothing.
      callee_code = <<0x60, 1, 0x60, 0, 0x55, 0x60, 0, 0x60, 0, 0xF3>>

      # CALL(0xFFFF, callee, 0, 0, 0, 0, 0); POP; clear slot 0; STOP.
      caller_code =
        <<0x60, 0, 0x60, 0, 0x60, 0, 0x60, 0, 0x60, 0, 0x60, callee, 0x61, 0xFF, 0xFF, 0xF1>> <>
          <<0x50, 0x60, 0, 0x60, 0, 0x55, 0x00>>

      sender = address_of(@private_key)

      db =
        InMemory.new(
          accounts: %{
            sender => %{balance: 10 ** 18},
            0xA => %{code: caller_code},
            callee => %{code: callee_code}
          },
          storage: %{0xA => %{0 => 7}}
        )

      {:ok, result} =
        EEVM.transact(signed_tx(0xA, <<>>), @block, db, hardfork: :cancun, tracer: true)

      assert result.status == :success
      steps = Tracer.steps(result.trace)

      call = Enum.find(steps, &(&1.op == :CALL))
      [callee_first | _] = callee_steps = Enum.filter(steps, &(&1.depth == 1))
      assert Enum.map(callee_steps, & &1.op) == [:PUSH1, :PUSH1, :SSTORE, :PUSH1, :PUSH1, :RETURN]

      # As in geth: EIP-2929 cold account access 2,600 plus the 0xFFFF forwarded,
      # which is less than all but 1/64 of the gas left (EIP-150).
      forwarded = 0xFFFF
      assert callee_first.gas_remaining == forwarded
      assert call.gas_cost == 2_600 + forwarded

      # The callee's own steps spend the forwarded gas, so it counts once.
      assert total_cost(steps) - forwarded + 21_000 - 4_800 == result.gas_used
    end

    test "CREATE does not count the gas it forwards to the init code" do
      # Init code: RETURN nothing (5 bytes), stored at memory 27..31, then
      # CREATE(0, 27, 5); STOP.
      code =
        <<0x64, 0x60, 0, 0x60, 0, 0xF3, 0x60, 0, 0x52>> <>
          <<0x60, 5, 0x60, 27, 0x60, 0, 0xF0, 0x00>>

      {_state, tracer} = trace_code(code, hardfork: :cancun)
      steps = Tracer.steps(tracer)

      # 32,000, plus EIP-3860's 2 per init code word; memory is already paid.
      assert Enum.find(steps, &(&1.op == :CREATE)).gas_cost == 32_002

      assert steps |> Enum.filter(&(&1.depth == 1)) |> Enum.map(& &1.op) == [
               :PUSH1,
               :PUSH1,
               :RETURN
             ]
    end

    test "a step that runs out of gas reports the cost it attempted" do
      # PUSH1 1, PUSH3 0xFFFFFF, MSTORE: memory would grow to 0xFFFFFF + 32
      # bytes, 524,289 words.
      {state, tracer} = trace_code(<<0x60, 1, 0x62, 0xFF, 0xFF, 0xFF, 0x52>>, gas: 10_000)
      assert state.status == :out_of_gas
      mstore = List.last(Tracer.steps(tracer))

      # 3 + memory cost 3 * w + w^2 / 512 for w = 524,289 (Yellow Paper eq. 326).
      assert {mstore.op, mstore.error, mstore.gas_cost} ==
               {:MSTORE, :out_of_gas, 3 + 3 * 524_289 + div(524_289 * 524_289, 512)}
    end

    test "a step that fails its stack check reports its static cost" do
      {_state, tracer} = trace_code(<<0x01>>)
      assert [%TraceStep{op: :ADD, gas_cost: 3, error: :stack_underflow}] = Tracer.steps(tracer)
    end

    defp total_cost(steps), do: steps |> Enum.map(& &1.gas_cost) |> Enum.sum()

    # EIP-2028 calldata cost on top of the 21,000 base.
    defp intrinsic_gas(data) do
      for <<byte <- data>>, reduce: 21_000 do
        gas -> gas + if(byte == 0, do: 4, else: 16)
      end
    end

    defp address_of(key) do
      {:ok, {x, y}} = ECDSA.public_key(:secp256k1, key)
      <<_::binary-12, address::160>> = Keccak.hash_256(<<x::256, y::256>>)
      address
    end

    defp signed_tx(to, data) do
      tx = %Legacy{nonce: 0, gas_price: 1, gas_limit: 200_000, to: to, value: 0, data: data}

      {:ok, {r, s, recovery_id}} =
        ECDSA.sign(:secp256k1, Signer.signing_hash(tx, 1), @private_key)

      %{tx | v: 37 + recovery_id, r: r, s: s}
    end

    defp balance_slot(owner), do: :binary.decode_unsigned(Keccak.hash_256(<<owner::256, 0::256>>))

    # transfer(to, amount) with balances at keccak256(owner . 0); emits
    # Transfer(from, to, amount) and returns true: the `erc20` program of
    # bench/interpreter_bench.exs.
    defp erc20 do
      Base.decode16!(
        "60003560E01C63A9059CBB146100155760006000FD5B336000526040600020805460243580821061" <>
          "0079578091039091556004356000526040600020805482019055600052600435337FDDF252AD1BE2" <>
          "C89B69C2B068FC378DAA952BA7F163C4A11628F55A4DF523B3EF60206000A3600160005260206000" <>
          "F35B60006000FD"
      )
    end
  end

  describe "nested calls track depth" do
    test "STATICCALL into a contract bumps depth in the child's trace" do
      alias EEVM.Context.Contract
      alias EEVM.Database.InMemory, as: DB

      callee_code = <<0x60, 0x42, 0x00>>
      callee_addr = 0xC0FFEE

      db =
        DB.new()
        |> EEVM.Database.put_code(callee_addr, callee_code)

      # STATICCALL gas addr argsOffset argsSize retOffset retSize
      # push args in reverse: 0, 0, 0, 0, addr, 0xFFFF
      caller_code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x62, 0xC0, 0xFF, 0xEE, 0x61, 0xFF,
          0xFF, 0xFA, 0x00>>

      {_state, tracer} =
        trace_code(caller_code,
          db: db,
          contract: %{Contract.new() | address: 0xCA11E2}
        )

      steps = Tracer.steps(tracer)
      parent_ops = Enum.filter(steps, &(&1.depth == 0))
      child_ops = Enum.filter(steps, &(&1.depth == 1))

      assert Enum.any?(parent_ops, &(&1.op == :STATICCALL))
      assert Enum.map(child_ops, & &1.op) == [:PUSH1, :STOP]
    end
  end

  describe "JSON output (EIP-3155 / geth --json)" do
    test "each line is valid JSON with geth-compatible keys" do
      {_state, tracer} = trace_code(<<0x60, 0x01, 0x00>>)
      [line1, line2] = Tracer.to_json_lines(tracer)

      decoded1 = Jason.decode!(line1)
      assert decoded1["op"] == 0x60
      assert decoded1["opName"] == "PUSH1"
      assert decoded1["pc"] == 0
      assert decoded1["depth"] == 1
      assert decoded1["stack"] == []
      assert decoded1["memSize"] == 0
      assert String.starts_with?(decoded1["gas"], "0x")
      assert String.starts_with?(decoded1["gasCost"], "0x")

      decoded2 = Jason.decode!(line2)
      assert decoded2["opName"] == "STOP"
      # After PUSH1, the stack has one element — encoded bottom-first, hex.
      assert decoded2["stack"] == ["0x1"]
    end

    test "to_json joins lines with newlines" do
      {_state, tracer} = trace_code(<<0x60, 0x01, 0x00>>)
      rendered = Tracer.to_json(tracer)
      assert length(String.split(rendered, "\n")) == 2
    end

    test "error steps include an error field" do
      {_state, tracer} = trace_code(<<0x01>>)
      [line] = Tracer.to_json_lines(tracer)
      assert Jason.decode!(line)["error"] == "stack_underflow"
    end
  end
end
