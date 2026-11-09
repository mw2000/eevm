defmodule EEVM.Interpreter.Instructions.DelegationTest do
  use ExUnit.Case, async: true

  alias EEVM.Context.Contract
  alias EEVM.{Database, Delegation, WorldState}
  alias EEVM.Interpreter.Memory

  @caller 0xCA11E2
  @authority 0xA0
  @delegate 0xDE1E
  @identity 0x04

  # ADDRESS PUSH1 0 SSTORE CALLER PUSH1 1 SSTORE STOP
  @record_context <<0x30, 0x60, 0x00, 0x55, 0x33, 0x60, 0x01, 0x55, 0x00>>

  describe "CALL-family opcodes from Prague" do
    test "CALL runs the delegate's code in the delegating account's context" do
      result = run(call(0xF1, @authority))

      assert EEVM.stack_values(result) == [1]
      assert Database.storage_load(result.db, @authority, 0) == @authority
      assert Database.storage_load(result.db, @authority, 1) == @caller
      assert Database.storage_load(result.db, @delegate, 0) == 0
    end

    test "DELEGATECALL and CALLCODE run the delegate's code in the caller's context" do
      for opcode <- [0xF4, 0xF2] do
        result = run(call(opcode, @authority))

        assert EEVM.stack_values(result) == [1]
        assert Database.storage_load(result.db, @caller, 0) == @caller
        assert Database.storage_load(result.db, @authority, 0) == 0
      end
    end

    test "charge the delegate's cold access on top of the target's" do
      direct = run(call(0xF1, @delegate))
      delegated = run(call(0xF1, @authority))
      warm_delegate = run(call(0xF1, @authority), warm: [@delegate])

      # Same code runs in both cases, so only the extra access differs.
      assert direct.frame.gas - delegated.frame.gas == 2_600
      assert direct.frame.gas - warm_delegate.frame.gas == 100
    end

    test "never dispatch to a precompile through a delegation" do
      accounts = %{@authority => %{code: Delegation.designator(@identity)}}

      direct = run(call(0xF1, @identity, input: <<0xAB>>), accounts: accounts)
      delegated = run(call(0xF1, @authority, input: <<0xAB>>), accounts: accounts)

      assert {EEVM.stack_values(direct), direct.frame.return_data} == {[1], <<0xAB>>}
      assert {EEVM.stack_values(delegated), delegated.frame.return_data} == {[1], <<>>}
    end

    test "do not follow designators before Prague" do
      result = run(call(0xF1, @authority), hardfork: :cancun)

      # 0xEF is an undefined opcode, so the call fails.
      assert EEVM.stack_values(result) == [0]
      assert Database.storage_load(result.db, @authority, 0) == 0
    end
  end

  test "EXTCODESIZE, EXTCODEHASH, and EXTCODECOPY read the designator itself" do
    designator = Delegation.designator(@delegate)

    # EXTCODESIZE(authority); EXTCODEHASH(authority); EXTCODECOPY(authority, 0, 0, 23)
    code =
      <<0x60, @authority, 0x3B, 0x60, @authority, 0x3F, 0x60, 23, 0x60, 0x00, 0x60, 0x00, 0x60,
        @authority, 0x3C, 0x00>>

    result = run(code)
    <<hash::unsigned-big-256>> = ExKeccak.hash_256(designator)

    assert EEVM.stack_values(result) == [hash, 23]
    assert Memory.read_bytes(result.frame.memory, 0, 23) |> elem(0) == designator
  end

  defp run(code, opts \\ []) do
    accounts =
      Map.merge(
        %{
          @caller => %{balance: 0},
          @authority => %{nonce: 1, code: Delegation.designator(@delegate)},
          @delegate => %{code: @record_context}
        },
        Keyword.get(opts, :accounts, %{})
      )

    EEVM.execute(code,
      gas: 1_000_000,
      hardfork: Keyword.get(opts, :hardfork, :prague),
      world_state: WorldState.new(accounts),
      contract: Contract.new(address: @caller, caller: 0xE0A),
      accessed_addresses: MapSet.new([@caller | Keyword.get(opts, :warm, [])])
    )
  end

  # Calls `target` with all available gas after storing `input` at memory 0.
  defp call(opcode, target, opts \\ []) do
    input = Keyword.get(opts, :input, <<>>)

    store_input =
      for {byte, i} <- Enum.with_index(:binary.bin_to_list(input)),
          into: <<>>,
          do: <<0x60, byte, 0x60, i, 0x53>>

    value = if opcode in [0xF1, 0xF2], do: <<0x60, 0x00>>, else: <<>>

    # retSize, retOffset, argsSize, argsOffset, [value], address, GAS
    store_input <>
      <<0x60, 0x20, 0x60, 0x20, 0x60, byte_size(input), 0x60, 0x00>> <>
      value <> <<0x73, target::unsigned-big-160, 0x5A, opcode, 0x00>>
  end
end
