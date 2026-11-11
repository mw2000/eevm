defmodule Devx.BlocksTest do
  use ExUnit.Case, async: true

  alias Devx.Blocks

  test "builds a Cancun block that round-trips through RLP and re-executes to the same roots" do
    config = EEVM.Config.new(:cancun, chain_id: 1)
    assert {:ok, block, built} = Blocks.build(config)

    # EIP-1559: an empty parent is below its gas target, so the base fee
    # falls by 1/8, from 1 gwei to 0.875 gwei.
    assert {block.header.number, block.header.base_fee_per_gas} == {101, 875_000_000}
    assert Enum.map(built.receipts, & &1.status) == [1, 1]

    assert {:ok, result} = Blocks.reexecute(block, config)
    assert result.gas_used == block.header.gas_used
    assert result.state_root == block.header.state_root

    <<_::96, token::160>> = EEVM.keccak256(<<0xD6, 0x94, Devx.sender()::160, 0x80>>)
    assert Devx.Erc20.balance_of(result.db, token, Devx.sender()) == 500
    assert EEVM.Database.get_balance(result.db, 0xB0B) == 5
  end

  test "rejects a block whose header doesn't match its body or result" do
    config = EEVM.Config.new(:cancun, chain_id: 1)
    {:ok, block, _} = Blocks.build(config)

    assert Blocks.reexecute(put_in(block.header.state_root, <<0::256>>), config) ==
             {:error, :invalid_state_root}

    assert Blocks.reexecute(%{block | transactions: Enum.reverse(block.transactions)}, config) ==
             {:error, :invalid_transactions_root}
  end

  @tag skip: "fresh state has no EIP-7002/7251 request contracts until #215"
  test "builds a Prague block on fresh state" do
    assert {:ok, _block, _result} = Blocks.build(EEVM.Config.new(:prague, chain_id: 1))
  end
end
