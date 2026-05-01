defmodule EEVM.TestSupport.TxExecutor do
  @moduledoc """
  Shared transaction-execution pipeline for the StateTest and BlockchainTest
  runners.

  Performs the steps a real client folds into block processing:
  validate → bump nonce → run the interpreter top-level → settle gas fees
  (sender debit, coinbase credit). Each runner wraps the result for its own
  post-state assertions.
  """

  alias EEVM.{Config, Database}
  alias EEVM.Context.{Block, Transaction}
  alias EEVM.Handler.Execution
  alias EEVM.Interpreter.MachineState
  alias EEVM.Transaction.{IntrinsicGas, Validator}

  @type result :: %{
          db: Database.t(),
          machine: MachineState.t(),
          gas_used: non_neg_integer(),
          failed?: boolean()
        }

  @spec execute(Transaction.t(), Database.t(), Block.t(), Config.t()) ::
          {:ok, result()} | {:error, term()}
  def execute(%Transaction{} = tx, %Database{} = db, %Block{} = block, %Config{} = config) do
    with :ok <- validate(tx, db, block, config) do
      db_after_nonce = Database.increment_nonce(db, tx.origin)
      machine = run_interpreter(tx, db_after_nonce, block, config)
      failed? = failed?(machine.status)
      settled = if failed?, do: db_after_nonce, else: machine.db
      gas_used = tx.gas_limit - machine.frame.gas

      with {:ok, finalized_db} <- apply_fees(settled, tx, block, gas_used) do
        {:ok, %{db: finalized_db, machine: machine, gas_used: gas_used, failed?: failed?}}
      end
    end
  end

  defp validate(%Transaction{} = tx, %Database{} = db, %Block{} = block, %Config{} = config) do
    case Validator.validate(tx, db, block, config.hardfork) do
      :ok -> :ok
      {:error, reason} -> {:error, {:validation, reason}}
    end
  end

  defp run_interpreter(
         %Transaction{} = tx,
         %Database{} = db,
         %Block{} = block,
         %Config{} = config
       ) do
    intrinsic_gas = IntrinsicGas.calculate(tx)
    execution_gas = max(tx.gas_limit - intrinsic_gas, 0)
    {machine, _new_address} = Execution.run_top_level(tx, db, block, config, execution_gas)
    machine
  end

  defp apply_fees(db, %Transaction{} = tx, %Block{} = block, gas_used) do
    sender_fee = gas_used * effective_gas_price(tx, block)
    miner_reward = gas_used * miner_reward_per_gas(tx, block)

    with {:ok, debited} <- debit_balance(db, tx.origin, sender_fee) do
      {:ok, credit_balance(debited, block.coinbase, miner_reward)}
    end
  end

  defp effective_gas_price(%Transaction{type: type} = tx, %Block{} = block)
       when type in [:eip1559, :eip4844] do
    min(tx.max_fee_per_gas, block.basefee + tx.max_priority_fee_per_gas)
  end

  defp effective_gas_price(%Transaction{} = tx, _block), do: tx.gasprice

  defp miner_reward_per_gas(%Transaction{type: type} = tx, %Block{} = block)
       when type in [:eip1559, :eip4844] do
    max(effective_gas_price(tx, block) - block.basefee, 0)
  end

  defp miner_reward_per_gas(%Transaction{} = tx, %Block{} = block) do
    max(tx.gasprice - block.basefee, 0)
  end

  defp failed?(status) when status in [:reverted, :invalid, :out_of_gas], do: true
  defp failed?({:error, _}), do: true
  defp failed?(_), do: false

  defp debit_balance(db, _addr, 0), do: {:ok, db}

  defp debit_balance(db, addr, amount) do
    current = Database.get_balance(db, addr)

    if current < amount do
      {:error, :insufficient_balance}
    else
      {:ok, Database.set_balance(db, addr, current - amount)}
    end
  end

  defp credit_balance(db, _addr, 0), do: db

  defp credit_balance(db, addr, amount),
    do: Database.set_balance(db, addr, Database.get_balance(db, addr) + amount)
end
