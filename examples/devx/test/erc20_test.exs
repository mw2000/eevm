defmodule Devx.Erc20Test do
  use ExUnit.Case, async: true

  alias Devx.Erc20

  @alice 0xA11CE
  @bob 0xB0B

  # The address CREATE gives `sender`'s first contract: the low 20 bytes of
  # keccak256(rlp([sender, 0])) (Yellow Paper §7), RLP written out by hand.
  defp first_contract_address(sender) do
    <<_::96, address::160>> = EEVM.keccak256(<<0xD6, 0x94, sender::160, 0x80>>)
    address
  end

  test "deploys the token at the CREATE address and mints the supply to the deployer" do
    {:ok, token, db, logs} = Erc20.deploy(EEVM.Database.InMemory.new(), @alice, 1_000_000)

    assert token == first_contract_address(@alice)
    assert Erc20.transfers(logs) == [{0, @alice, 1_000_000}]
    assert Erc20.balance_of(db, token, @alice) == 1_000_000
    assert Erc20.balance_of(db, token, @bob) == 0
  end

  test "transfer moves tokens, returns true, and emits Transfer" do
    {:ok, token, db, _logs} = Erc20.deploy(EEVM.Database.InMemory.new(), @alice, 1_000_000)

    {:ok, result} = Erc20.transfer(db, token, @alice, @bob, 250)

    assert result.status == :success
    assert result.return_data == <<1::256>>
    assert Erc20.transfers(result.logs) == [{@alice, @bob, 250}]
    assert Erc20.balance_of(result.db, token, @alice) == 999_750
    assert Erc20.balance_of(result.db, token, @bob) == 250
  end
end
