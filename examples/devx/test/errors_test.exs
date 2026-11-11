defmodule Devx.ErrorsTest do
  use ExUnit.Case, async: true

  alias Devx.Errors

  setup do
    # create/3 bumps the deployer's nonce, so its next transaction is nonce 1.
    {:ok, token, db, _logs} = Devx.Erc20.deploy(Devx.funded_db(), Devx.sender(), 100)
    %{token: token, db: db, me: Devx.sender()}
  end

  test "a require reverts with its reason string", %{token: t, db: db, me: me} do
    assert {:revert, {:error_string, "ERC20: insufficient balance"}, _gas} =
             Errors.call(db, t, me, "transfer(address,uint256)", [0xB0B, 10_000])

    assert Errors.transact(db, t, "transfer(address,uint256)", [0xB0B, 10_000], nonce: 1) ==
             {:ok, :revert, {:error_string, "ERC20: insufficient balance"}, 0}
  end

  test "a custom error reverts with its selector and arguments", %{token: t, db: db} do
    assert {:revert, {:custom, selector, <<0x999::256>>}, _gas} =
             Errors.call(db, t, 0x999, "mint(uint256)", [1])

    assert selector == EEVM.selector("Unauthorized(address)")
  end

  test "division by zero panics with code 0x12", %{token: t, db: db, me: me} do
    # Solidity docs, \"Panic via assert and Error via require\": 0x12 is division by zero.
    assert {:revert, {:panic, 0x12}, _gas} =
             Errors.call(db, t, me, "divide(uint256,uint256)", [1, 0])
  end

  test "running out of gas halts and uses all of it", %{token: t, db: db, me: me} do
    assert Errors.call(db, t, me, "burnGas()", [], gas: 50_000) ==
             {{:halt, :out_of_gas}, nil, 50_000}

    assert Errors.transact(db, t, "burnGas()", [], nonce: 1) ==
             {:ok, {:halt, :out_of_gas}, nil, 0}
  end

  test "invalid transactions are rejected before executing, with a message", %{token: t, db: db} do
    transfer = "transfer(address,uint256)"

    assert Errors.transact(db, t, transfer, [0xB0B, 1], nonce: 0) ==
             {:error, :nonce_too_low, "nonce too low"}

    assert Errors.transact(db, t, transfer, [0xB0B, 1], nonce: 3) ==
             {:error, :nonce_too_high, "nonce too high"}

    assert {:error, :invalid_chain_id, _message} =
             Errors.transact(db, t, transfer, [0xB0B, 1], nonce: 1, chain_id: 5)

    # 21,000 + calldata (EIP-2028) is above 21,000.
    assert {:error, :intrinsic_gas_too_low, _} =
             Errors.transact(db, t, transfer, [0xB0B, 1], nonce: 1, gas_limit: 21_000)

    assert {:error, :insufficient_balance, _} =
             Errors.transact(db, t, transfer, [0xB0B, 1], nonce: 1, value: 10 ** 30)

    assert {:error, :invalid_fields, _} = Errors.transact_raw(db, <<0x02, 0xC0>>)
  end

  test "with details: true, a rejection carries the values it compared", %{
    token: t,
    db: db,
    me: me
  } do
    transfer = "transfer(address,uint256)"

    assert {:error, :nonce_too_high, %{sender: ^me, tx_nonce: 5, state_nonce: 1}, message} =
             Errors.transact_with_details(db, t, transfer, [0xB0B, 1], nonce: 5)

    assert message =~ "nonce too high"
    assert message =~ "tx_nonce 5"

    # EIP-2028 intrinsic gas: 21,000 plus 16 per non-zero and 4 per zero
    # calldata byte. transfer(0xB0B, 1) is a 4-byte selector, all non-zero,
    # and two words with 2 and 1 non-zero bytes: 21,000 + 7·16 + 61·4 = 21,356.
    assert {:error, :intrinsic_gas_too_low, %{gas_limit: 21_000, intrinsic_gas: 21_356}, _} =
             Errors.transact_with_details(db, t, transfer, [0xB0B, 1],
               nonce: 1,
               gas_limit: 21_000
             )
  end
end
