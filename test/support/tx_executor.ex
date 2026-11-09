defmodule EEVM.TestSupport.TxExecutor do
  @moduledoc """
  Transaction-execution pipeline for the StateTest runner, which builds
  unsigned `EEVM.TxEnv`s from a fixture's secret key and so
  can't go through `EEVM.Handler`.

  Performs the steps a real client folds into block processing:
  validate → charge the gas and EIP-4844 blob gas fees and bump nonce → apply
  EIP-7702 authorizations → run the interpreter top-level → refund unused gas
  and credit the coinbase.
  """

  alias EEVM.{BlockEnv, Config, Database, TxEnv}
  alias EEVM.Handler.{Execution, PreExecution}
  alias EEVM.Interpreter.MachineState
  alias EEVM.Transaction.{IntrinsicGas, Validator}

  @type result :: %{
          db: Database.t(),
          machine: MachineState.t(),
          gas_used: non_neg_integer(),
          failed?: boolean()
        }

  @spec execute(TxEnv.t(), Database.t(), BlockEnv.t(), Config.t()) ::
          {:ok, result()} | {:error, term()}
  def execute(%TxEnv{} = tx, %Database{} = db, %BlockEnv{} = block, %Config{} = config) do
    with :ok <- validate(tx, db, block, config),
         # GASPRICE (0x3A) reads the price per gas the sender pays (EIP-1559).
         tx = %{tx | gas_price: PreExecution.effective_gas_price(tx, block)},
         # The sender pays gas_limit * gas price and the blob fee before execution
         # (execution-specs process_transaction), so BALANCE sees the debited balance.
         {:ok, db_after_fees} <-
           debit_balance(
             db,
             tx.origin,
             tx.gas_limit * tx.gas_price + PreExecution.blob_gas_fee(tx, block)
           ) do
      db_after_nonce = Database.increment_nonce(db_after_fees, tx.origin)

      {db_authorized, authorization} =
        PreExecution.apply_authorizations(db_after_nonce, tx, config.chain_id)

      machine = run_interpreter(tx, db_authorized, block, config, authorization)
      failed? = failed?(machine.status)
      settled = if failed?, do: db_authorized, else: machine.db
      gas_used = tx.gas_limit - machine.frame.gas

      finalized_db =
        settled
        |> credit_balance(tx.origin, (tx.gas_limit - gas_used) * tx.gas_price)
        |> credit_balance(block.coinbase, gas_used * max(tx.gas_price - block.base_fee, 0))

      {:ok, %{db: finalized_db, machine: machine, gas_used: gas_used, failed?: failed?}}
    end
  end

  defp validate(%TxEnv{} = tx, %Database{} = db, %BlockEnv{} = block, %Config{} = config) do
    case Validator.validate(tx, db, block, config.hardfork) do
      :ok -> :ok
      {:error, reason} -> {:error, {:validation, reason}}
    end
  end

  defp run_interpreter(
         %TxEnv{} = tx,
         %Database{} = db,
         %BlockEnv{} = block,
         %Config{} = config,
         authorization
       ) do
    intrinsic_gas = IntrinsicGas.calculate(tx, config.hardfork)
    execution_gas = max(tx.gas_limit - intrinsic_gas, 0)

    {machine, _new_address} =
      Execution.run_top_level(tx, db, block, config, execution_gas, authorization)

    machine
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
