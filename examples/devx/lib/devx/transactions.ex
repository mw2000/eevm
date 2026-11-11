defmodule Devx.Transactions do
  @moduledoc "Task 3: sign and execute a legacy and an EIP-1559 transaction against in-memory state."

  alias EEVM.Transaction.{Envelope, FeeMarket, Legacy, Signer}

  @doc "A signed legacy transfer at 2 gwei."
  def legacy(nonce, to, value) do
    %Legacy{nonce: nonce, gas_price: 2 * Devx.gwei(), gas_limit: 21_000, to: to, value: value}
    |> Signer.sign(Devx.private_key(), Devx.config())
  end

  @doc "A signed EIP-1559 transfer: at most 3 gwei, of which up to 2 gwei is the tip."
  def eip1559(nonce, to, value) do
    %FeeMarket{
      nonce: nonce,
      max_fee_per_gas: 3 * Devx.gwei(),
      max_priority_fee_per_gas: 2 * Devx.gwei(),
      gas_limit: 21_000,
      to: to,
      value: value
    }
    |> Signer.sign(Devx.private_key(), Devx.config())
  end

  @doc "Executes `tx` on `db` in `Devx.block_env/0`."
  def execute(tx, db), do: EEVM.transact(tx, Devx.block_env(), db, config: Devx.config())

  @doc "The raw signed bytes of `tx`, as `eth_sendRawTransaction` takes them."
  def raw(tx), do: Envelope.encode(tx)

  @doc "Sends a legacy and then an EIP-1559 transfer to `to`; the second goes in as raw bytes."
  def legacy_then_eip1559(to) do
    {:ok, legacy} = legacy(0, to, 10 ** 15)
    {:ok, first} = execute(legacy, Devx.funded_db())
    {:ok, typed} = eip1559(1, to, 1)
    {:ok, second} = execute(raw(typed), first.db)
    {first, second}
  end

  @doc "Reads a balance."
  def balance(db, address), do: EEVM.Database.get_balance(db, address)
end
