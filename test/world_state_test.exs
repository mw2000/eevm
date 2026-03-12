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

  test "tracks nonce updates" do
    world_state = WorldState.new()

    assert WorldState.get_nonce(world_state, 1) == 0

    updated =
      world_state
      |> WorldState.increment_nonce(1)
      |> WorldState.increment_nonce(1)

    assert WorldState.get_nonce(updated, 1) == 2
  end

  test "transfers value between accounts" do
    world_state = WorldState.new(%{1 => %{balance: 5}, 2 => %{balance: 3}})

    assert {:ok, updated} = WorldState.transfer(world_state, 1, 2, 4)
    assert WorldState.get_balance(updated, 1) == 1
    assert WorldState.get_balance(updated, 2) == 7
  end

  test "transfer fails when source has insufficient balance" do
    world_state = WorldState.new(%{1 => %{balance: 1}, 2 => %{balance: 3}})

    assert {:error, :insufficient_balance} = WorldState.transfer(world_state, 1, 2, 4)
  end
end
