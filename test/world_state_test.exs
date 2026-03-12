defmodule EEVM.WorldStateTest do
  use ExUnit.Case, async: true

  alias EEVM.WorldState

  test "returns code and balance for existing account" do
    world_state = WorldState.new(%{1 => %{code: <<0xAA>>, balance: 7}})

    assert WorldState.account_exists?(world_state, 1)
    assert WorldState.get_code(world_state, 1) == <<0xAA>>
    assert WorldState.get_balance(world_state, 1) == 7
  end

  test "returns defaults for missing account" do
    world_state = WorldState.new()

    refute WorldState.account_exists?(world_state, 1)
    assert WorldState.get_account(world_state, 1) == nil
    assert WorldState.get_code(world_state, 1) == <<>>
    assert WorldState.get_balance(world_state, 1) == 0
  end
end
