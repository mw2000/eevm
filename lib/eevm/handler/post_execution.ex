defmodule EEVM.Handler.PostExecution do
  @moduledoc """
  Steps 9-11 of the transaction pipeline:

  - **Settle gas refund** — the sender was debited `gas_limit * max_price`
    upfront. They actually owe `gas_used * effective_price`. Refund the
    difference. On a successful tx the refund lands in the EVM-side db (which
    already reflects every side effect); on revert / out-of-gas / invalid it
    lands in the post-upfront, post-nonce-bump db (since EVM mutations are
    dropped).

  - **Coinbase reward** — credit the block proposer
    `(effective_price - basefee) * gas_used`.

  - **Build receipt + result** — produce the `EEVM.TransactionResult`
    struct that callers consume.
  """

  alias EEVM.{Bloom, Database, TransactionResult}
  alias EEVM.Context.{Block, Transaction}
  alias EEVM.Handler.{PreExecution, Validation}
  alias EEVM.Interpreter.MachineState

  @spec finalize(
          MachineState.t(),
          non_neg_integer() | nil,
          Transaction.t(),
          binary(),
          Database.t(),
          Block.t()
        ) :: {:ok, TransactionResult.t()}
  def finalize(
        %MachineState{} = final_state,
        contract_address,
        %Transaction{} = tx,
        sender_bytes,
        %Database{} = db_nonce_bumped,
        %Block{} = block
      ) do
    gas_used = tx.gas_limit - final_state.gas
    effective_price = PreExecution.effective_gas_price(tx, block)

    settled_db = settle_state(final_state, db_nonce_bumped, tx, gas_used, effective_price)
    coinbase_credited_db = credit_coinbase(settled_db, block, tx, gas_used, effective_price)

    status = result_status(final_state.status)

    logs = if status == :success, do: final_state.logs, else: []
    logs_bloom = Bloom.from_logs(logs)
    receipt_status = if status == :success, do: 1, else: 0

    receipt = %{
      status: receipt_status,
      cumulative_gas_used: gas_used,
      logs_bloom: logs_bloom,
      logs: logs
    }

    {:ok,
     %TransactionResult{
       status: status,
       gas_used: gas_used,
       gas_refunded: max(final_state.gas, 0),
       sender: Validation.decode_address(sender_bytes),
       logs: logs,
       logs_bloom: logs_bloom,
       receipt: receipt,
       post_state_db: coinbase_credited_db,
       return_data: if(status == :success, do: final_state.return_data, else: <<>>),
       contract_address: if(status == :success, do: contract_address, else: nil)
     }}
  end

  defp settle_state(%MachineState{status: status}, db_nonce_bumped, tx, gas_used, effective_price)
       when status in [:reverted, :invalid, :out_of_gas] or is_tuple(status) do
    refund_amount = PreExecution.gas_upfront(tx) - gas_used * effective_price
    credit_sender(db_nonce_bumped, tx.origin, refund_amount)
  end

  defp settle_state(%MachineState{} = state, _db_nonce_bumped, tx, gas_used, effective_price) do
    refund_amount = PreExecution.gas_upfront(tx) - gas_used * effective_price
    credit_sender(state.db, tx.origin, refund_amount)
  end

  defp credit_coinbase(%Database{} = db, %Block{}, _tx, 0, _price), do: db

  defp credit_coinbase(%Database{} = db, %Block{} = block, %Transaction{} = tx, gas_used, _price) do
    priority_per_gas = max(PreExecution.effective_gas_price(tx, block) - block.basefee, 0)
    reward = priority_per_gas * gas_used

    if reward == 0 do
      db
    else
      credit_sender(db, block.coinbase, reward)
    end
  end

  defp credit_sender(%Database{} = db, _address, 0), do: db

  defp credit_sender(%Database{} = db, address, amount) do
    current = Database.get_balance(db, address)
    Database.set_balance(db, address, current + amount)
  end

  defp result_status(:stopped), do: :success
  defp result_status(:reverted), do: :reverted
  defp result_status(_), do: :reverted
end
