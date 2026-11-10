defmodule EEVM.Interpreter.Instructions.System.EIP161Test do
  use ExUnit.Case, async: true
  import EEVM.TestSupport.MachineHelpers

  alias EEVM.Database
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
end
