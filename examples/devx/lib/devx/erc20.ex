defmodule Devx.Erc20 do
  @moduledoc """
  Task 2: deploy an ERC-20 from solc output and call `transfer` and
  `balanceOf`, without keys or signed transactions (`EEVM.create/3` and
  `EEVM.call/4`, like ethereumjs's `runCall`), with `EEVM.ABI` encoding the
  calls and decoding their results and events.
  """

  @transfer_event "Transfer(address indexed from, address indexed to, uint256 value)"

  @doc "Deploys the token from `owner` with `supply` tokens. Returns `{:ok, token, db, logs}`."
  def deploy(db, owner, supply) do
    {:ok, result} = EEVM.create(db, Devx.token_initcode(supply), caller: owner)

    case result.status do
      :success -> {:ok, result.contract_address, result.db, result.logs}
      status -> {:error, status}
    end
  end

  @doc "Calls `transfer(to, amount)` from `from`. Returns the call result."
  def transfer(db, token, from, to, amount) do
    EEVM.call(db, token, EEVM.ABI.encode_call("transfer(address,uint256)", [to, amount]),
      caller: from
    )
  end

  @doc "Reads `balanceOf(who)`."
  def balance_of(db, token, who) do
    {:ok, result} = EEVM.call(db, token, EEVM.ABI.encode_call("balanceOf(address)", [who]))
    {:ok, [balance]} = EEVM.ABI.decode(["uint256"], result.return_data)
    balance
  end

  @doc "Reads `name()`, a `string`."
  def name(db, token) do
    {:ok, result} = EEVM.call(db, token, EEVM.ABI.encode_call("name()", []))
    {:ok, [name]} = EEVM.ABI.decode(["string"], result.return_data)
    name
  end

  @doc "Decodes the ERC-20 `Transfer` events in `logs` as `{from, to, value}`."
  def transfers(logs) do
    for log <- logs,
        {:ok, [from, to, value]} <- [EEVM.ABI.decode_log(@transfer_event, log)],
        do: {from, to, value}
  end
end
