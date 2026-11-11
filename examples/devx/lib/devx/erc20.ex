defmodule Devx.Erc20 do
  @moduledoc """
  Task 2: deploy an ERC-20 from solc output and call `transfer` and
  `balanceOf`, without keys or signed transactions (`EEVM.create/3` and
  `EEVM.call/4`, like ethereumjs's `runCall`).
  """

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
    calldata = EEVM.selector("transfer(address,uint256)") <> <<to::256, amount::256>>
    EEVM.call(db, token, calldata, caller: from)
  end

  @doc "Reads `balanceOf(who)`."
  def balance_of(db, token, who) do
    {:ok, result} = EEVM.call(db, token, EEVM.selector("balanceOf(address)") <> <<who::256>>)
    :binary.decode_unsigned(result.return_data)
  end

  @doc "Decodes the ERC-20 `Transfer` events in `logs` as `{from, to, value}`."
  def transfers(logs) do
    topic = EEVM.event_topic("Transfer(address,address,uint256)")

    for %{topics: [^topic, from, to], data: <<value::256>>} <- logs, do: {from, to, value}
  end
end
