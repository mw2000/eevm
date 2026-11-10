defmodule EEVM.Interpreter.Instructions.System.EIP161Test do
  use ExUnit.Case, async: true
  import EEVM.TestSupport.MachineHelpers

  alias EEVM.{Config, Database}
  alias EEVM.Database.InMemory

  test "zero-value CALL to empty account removes it at tx end" do
    world_state = InMemory.new(accounts: %{0xAA => %{}})

    code =
      <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0xAA, 0x61, 0xFF, 0xFF,
        0xF1, 0x00>>

    result = run_code(code, db: world_state, gas: 1_000_000)

    assert result.status == :stopped
    assert stack_values(result) == [1]
    assert Database.get_account(result.db, 0xAA) == nil
  end

  test "zero-value CALL to non-empty account preserves it" do
    world_state = InMemory.new(accounts: %{0xAA => %{nonce: 1}})

    code =
      <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0xAA, 0x61, 0xFF, 0xFF,
        0xF1, 0x00>>

    result = run_code(code, db: world_state, gas: 1_000_000)

    assert result.status == :stopped
    assert stack_values(result) == [1]
    assert Database.get_account(result.db, 0xAA) == %{balance: 0, nonce: 1, code: <<>>}
  end

  test "touches from reverted child calls do not survive" do
    child_code =
      <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0xAA, 0x61, 0xFF, 0xFF,
        0xF1, 0x60, 0x00, 0x60, 0x00, 0xFD>>

    world_state = InMemory.new(accounts: %{0x10 => %{code: child_code}, 0xAA => %{}})

    parent_code =
      <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x10, 0x61, 0xFF, 0xFF,
        0xF1, 0x00>>

    result = run_code(parent_code, db: world_state, gas: 1_000_000)

    assert result.status == :stopped
    assert stack_values(result) == [0]
    assert Database.get_account(result.db, 0xAA) == %{balance: 0, nonce: 0, code: <<>>}
  end

  test "SELFDESTRUCT beneficiary is touched and cleared when empty" do
    world_state = InMemory.new(accounts: %{0xAA => %{}})
    code = <<0x60, 0xAA, 0xFF>>

    result = run_code(code, db: world_state, gas: 1_000_000)

    assert result.status == :stopped
    assert Database.get_account(result.db, 0xAA) == nil
  end

  describe "before EIP-161" do
    # CALL(0xFFFF, target, 0, 0, 0, 0, 0) STOP. execution-specs Frontier
    # process_message touches the target, creating it even with no value,
    # and a precompile target is no exception (EEST frontier/opcodes/test_double_kill,
    # frontier/precompiles/test_precompiles).
    defp zero_value_call(target),
      do:
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, target, 0x61, 0xFF,
          0xFF, 0xF1, 0x00>>

    test "a zero-value CALL creates a missing target, precompile or not" do
      for target <- [0xAA, 0x01] do
        result = run_code(zero_value_call(target), gas: 1_000_000, config: Config.new(:homestead))

        assert stack_values(result) == [1]
        assert Database.get_account(result.db, target) == %{balance: 0, nonce: 0, code: <<>>}
      end
    end

    test "a reverted child's touch does not create its target" do
      child_code = binary_part(zero_value_call(0xAA), 0, 16) <> <<0x60, 0x00, 0x60, 0x00, 0xFD>>
      db = InMemory.new(accounts: %{0x10 => %{code: child_code}})

      result =
        run_code(zero_value_call(0x10), db: db, gas: 1_000_000, config: Config.new(:frontier))

      assert stack_values(result) == [0]
      refute Database.account_exists?(result.db, 0xAA)
    end
  end
end
