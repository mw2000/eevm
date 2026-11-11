defmodule Devx.TransactionsTest do
  use ExUnit.Case, async: true

  alias Devx.Transactions
  alias EEVM.Transaction.Envelope

  @gwei 1_000_000_000
  @recipient 0xB0B
  @coinbase 0xC0FFEE

  test "the funded key is the EIP-155 example key" do
    assert EEVM.hex(<<Devx.sender()::160>>) == "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f"
  end

  test "a legacy and then a raw EIP-1559 transfer pay value, gas, and tips" do
    {first, second} = Transactions.legacy_then_eip1559(@recipient)

    assert {first.status, first.gas_used, first.sender} == {:success, 21_000, Devx.sender()}
    assert {first.receipt.tx_type, first.receipt.status} == {:legacy, 1}

    assert {second.status, second.gas_used, second.receipt.tx_type} ==
             {:success, 21_000, :eip1559}

    # Base fee 1 gwei. Legacy pays its 2 gwei price; the coinbase keeps the
    # 1 gwei above the base fee. EIP-1559 pays base + min(tip 2, max 3 - base 1)
    # = 3 gwei, and the coinbase keeps the 2 gwei tip (EIP-1559).
    db = second.db
    assert Transactions.balance(db, @recipient) == 10 ** 15 + 1
    assert Transactions.balance(db, @coinbase) == 21_000 * 1 * @gwei + 21_000 * 2 * @gwei

    assert Transactions.balance(db, Devx.sender()) ==
             10 ** 18 - (10 ** 15 + 21_000 * 2 * @gwei) - (1 + 21_000 * 3 * @gwei)
  end

  test "raw bytes decode to the signed transaction" do
    {:ok, tx} = Transactions.eip1559(0, @recipient, 1)
    assert <<0x02, _::binary>> = raw = Transactions.raw(tx)
    assert Envelope.decode(raw) == {:ok, tx}
  end
end
