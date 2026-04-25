defmodule EEVM.Handler.PreExecution do
  @moduledoc """
  Steps 4-7 of the transaction pipeline (Yellow Paper §6):

  - **Charge upfront** — debit `gas_limit * max_price` from the sender. The
    `value` portion is *not* debited here; it is moved by `Execution` when
    the call frame is set up so the same wei is not deducted twice.
  - **Intrinsic gas** — verify `tx.gas_limit >= IntrinsicGas.calculate(tx)`
    and compute the gas available to the EVM as the difference.
  - **Bump nonce** — increment the sender's nonce.
  - **Pre-warm access set** — seed `accessed_addresses` and
    `accessed_storage_keys` with EIP-2929 / EIP-3651 entries plus the
    transaction's access list.

  Also exposes `gas_upfront/1` and `effective_gas_price/2` because both
  `PostExecution` settlement and the upfront balance check share the same
  fee-market formula.
  """

  alias EEVM.{Database, Precompiles}
  alias EEVM.Context.{Block, Contract, Transaction}
  alias EEVM.Transaction.IntrinsicGas

  @spec charge_upfront(Database.t(), Transaction.t(), Block.t()) ::
          {:ok, Database.t()} | {:error, atom()}
  def charge_upfront(%Database{} = db, %Transaction{} = tx, %Block{} = block) do
    sender_balance = Database.get_balance(db, tx.origin)
    gas_charge = gas_upfront(tx)

    cond do
      sender_balance < gas_charge + tx.value ->
        {:error, :insufficient_balance}

      effective_gas_price(tx, block) < block.basefee ->
        {:error, :effective_gas_price_below_basefee}

      true ->
        debited = Database.set_balance(db, tx.origin, sender_balance - gas_charge)
        {:ok, debited}
    end
  end

  @doc """
  Verify intrinsic gas, bump the sender nonce, and return the gas available
  to the EVM.
  """
  @spec prepare_execution(Database.t(), Transaction.t()) ::
          {:ok, Database.t(), non_neg_integer()} | {:error, :intrinsic_gas_too_low}
  def prepare_execution(%Database{} = db, %Transaction{} = tx) do
    intrinsic = IntrinsicGas.calculate(tx)

    if tx.gas_limit < intrinsic do
      {:error, :intrinsic_gas_too_low}
    else
      execution_gas = tx.gas_limit - intrinsic
      db_nonce_bumped = Database.increment_nonce(db, tx.origin)
      {:ok, db_nonce_bumped, execution_gas}
    end
  end

  @spec gas_upfront(Transaction.t()) :: non_neg_integer()
  def gas_upfront(%Transaction{type: type} = tx) when type in [:eip1559, :eip4844] do
    tx.gas_limit * tx.max_fee_per_gas
  end

  def gas_upfront(%Transaction{} = tx), do: tx.gas_limit * tx.gasprice

  @spec effective_gas_price(Transaction.t(), Block.t()) :: non_neg_integer()
  def effective_gas_price(%Transaction{type: type} = tx, %Block{} = block)
      when type in [:eip1559, :eip4844] do
    min(tx.max_fee_per_gas, block.basefee + tx.max_priority_fee_per_gas)
  end

  def effective_gas_price(%Transaction{} = tx, %Block{}), do: tx.gasprice

  @spec initial_accessed_addresses(Transaction.t(), EEVM.Config.t(), Contract.t(), Block.t()) ::
          MapSet.t(non_neg_integer())
  def initial_accessed_addresses(tx, config, contract_ctx, block) do
    base =
      MapSet.new()
      |> MapSet.put(contract_ctx.address)
      |> MapSet.put(contract_ctx.caller)
      |> MapSet.put(tx.origin)
      |> MapSet.put(block.coinbase)
      |> then(fn set ->
        Enum.reduce(Precompiles.precompile_addresses(config), set, &MapSet.put(&2, &1))
      end)

    Enum.reduce(tx.access_list, base, fn {address, _slots}, acc ->
      MapSet.put(acc, address)
    end)
  end

  @spec initial_accessed_storage_keys(Transaction.t()) ::
          MapSet.t({non_neg_integer(), non_neg_integer()})
  def initial_accessed_storage_keys(tx) do
    Enum.reduce(tx.access_list, MapSet.new(), fn {address, slots}, acc ->
      Enum.reduce(slots, acc, fn slot, inner -> MapSet.put(inner, {address, slot}) end)
    end)
  end
end
