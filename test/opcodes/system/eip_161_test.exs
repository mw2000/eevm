defmodule EEVM.Opcodes.System.EIP161Test do
  use ExUnit.Case, async: true

  alias EEVM.Database
  alias EEVM.WorldState

  test "zero-value CALL to empty account removes it at tx end" do
    world_state = WorldState.new(%{0xAA => %{}})

    code =
      <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0xAA, 0x61, 0xFF, 0xFF,
        0xF1, 0x00>>

    result = EEVM.execute(code, world_state: world_state, gas: 1_000_000)

    assert result.status == :stopped
    assert EEVM.stack_values(result) == [1]
    assert Database.get_account(result.db, 0xAA) == nil
  end

  test "zero-value CALL to non-empty account preserves it" do
    world_state = WorldState.new(%{0xAA => %{nonce: 1}})

    code =
      <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0xAA, 0x61, 0xFF, 0xFF,
        0xF1, 0x00>>

    result = EEVM.execute(code, world_state: world_state, gas: 1_000_000)

    assert result.status == :stopped
    assert EEVM.stack_values(result) == [1]
    assert Database.get_account(result.db, 0xAA) == %{nonce: 1}
  end

  test "touches from reverted child calls do not survive" do
    child_code =
      <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0xAA, 0x61, 0xFF, 0xFF,
        0xF1, 0x60, 0x00, 0x60, 0x00, 0xFD>>

    world_state = WorldState.new(%{0x10 => %{code: child_code}, 0xAA => %{}})

    parent_code =
      <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x10, 0x61, 0xFF, 0xFF,
        0xF1, 0x00>>

    result = EEVM.execute(parent_code, world_state: world_state, gas: 1_000_000)

    assert result.status == :stopped
    assert EEVM.stack_values(result) == [0]
    assert Database.get_account(result.db, 0xAA) == %{}
  end

  test "SELFDESTRUCT beneficiary is touched and cleared when empty" do
    world_state = WorldState.new(%{0xAA => %{}})
    code = <<0x60, 0xAA, 0xFF>>

    result = EEVM.execute(code, world_state: world_state, gas: 1_000_000)

    assert result.status == :stopped
    assert Database.get_account(result.db, 0xAA) == nil
  end
end
