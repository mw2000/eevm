defmodule EEVM.Handler.PostExecution do
  @moduledoc """
  Steps 9-11 of the transaction pipeline:

  - **Settle gas refund** — the sender was debited `gas_limit * max_price`
    upfront. They actually owe `gas_used * effective_price`. Refund the
    difference. On a successful tx the refund lands in the EVM-side db (which
    already reflects every side effect); on revert / out-of-gas / invalid it
    lands in the post-upfront, post-nonce-bump db, which also holds any
    EIP-7702 delegations (since EVM mutations are dropped).

  - **Coinbase reward** — credit the block proposer
    `(effective_price - basefee) * gas_used`.

  - **Build receipt + result** — produce the `EEVM.TransactionResult`
    struct that callers consume.
  """

  alias EEVM.Block.Receipt
  alias EEVM.BlockEnv
  alias EEVM.CallResult
  alias EEVM.Database
  alias EEVM.Handler.PreExecution
  alias EEVM.Interpreter.MachineState
  alias EEVM.TransactionResult
  alias EEVM.TxEnv

  @doc """
  Settle gas, credit the coinbase, and build the `EEVM.TransactionResult`.

  The database argument is the state after upfront charging, the nonce
  bump, and EIP-7702 authorizations; settlement starts from it when
  execution failed.
  """
  @spec finalize(
          MachineState.t(),
          non_neg_integer() | nil,
          TxEnv.t(),
          non_neg_integer(),
          Database.t(),
          BlockEnv.t()
        ) :: {:ok, TransactionResult.t()}
  def finalize(
        %MachineState{} = final_state,
        contract_address,
        %TxEnv{} = tx,
        sender,
        %Database{} = db_nonce_bumped,
        %BlockEnv{} = block
      ) do
    gas_used = tx.gas_limit - final_state.frame.gas
    effective_price = PreExecution.effective_gas_price(tx, block)

    settled_db = settle_state(final_state, db_nonce_bumped, tx, gas_used, effective_price)
    coinbase_credited_db = credit_coinbase(settled_db, block, tx, gas_used, effective_price)

    status = status(final_state.status)
    logs = if status == :success, do: Enum.reverse(final_state.substate.logs), else: []

    receipt =
      Receipt.new(
        tx_type: tx.type,
        status: if(status == :success, do: 1, else: 0),
        cumulative_gas_used: gas_used,
        logs: logs
      )

    {:ok,
     %TransactionResult{
       status: status,
       gas_used: gas_used,
       gas_refunded: max(final_state.frame.gas, 0),
       sender: sender,
       contract_address: if(status == :success, do: contract_address, else: nil),
       return_data: if(status == :success, do: final_state.frame.return_data, else: <<>>),
       logs: logs,
       receipt: receipt,
       db: coinbase_credited_db,
       trace: final_state.tracer,
       post_state_db: coinbase_credited_db,
       logs_bloom: receipt.logs_bloom
     }}
  end

  @doc """
  Maps the interpreter's final machine status to the public status of
  `EEVM.CallResult` and `EEVM.TransactionResult`.

  ## Examples

      iex> EEVM.Handler.PostExecution.status(:stopped)
      :success
      iex> EEVM.Handler.PostExecution.status(:invalid)
      {:halt, :invalid_opcode}
  """
  @spec status(MachineState.status()) :: CallResult.status()
  def status(:stopped), do: :success
  def status(:reverted), do: :revert
  def status(:invalid), do: {:halt, :invalid_opcode}
  def status(:out_of_gas), do: {:halt, :out_of_gas}
  def status({:error, reason}), do: {:halt, reason}

  defp settle_state(%MachineState{status: status}, db_nonce_bumped, tx, gas_used, effective_price)
       when status in [:reverted, :invalid, :out_of_gas] or is_tuple(status) do
    refund_amount = PreExecution.gas_upfront(tx) - gas_used * effective_price
    credit_sender(db_nonce_bumped, tx.origin, refund_amount)
  end

  defp settle_state(%MachineState{} = state, _db_nonce_bumped, tx, gas_used, effective_price) do
    refund_amount = PreExecution.gas_upfront(tx) - gas_used * effective_price
    credit_sender(state.db, tx.origin, refund_amount)
  end

  defp credit_coinbase(%Database{} = db, %BlockEnv{}, _tx, 0, _price), do: db

  defp credit_coinbase(%Database{} = db, %BlockEnv{} = block, %TxEnv{} = tx, gas_used, _price) do
    priority_per_gas = max(PreExecution.effective_gas_price(tx, block) - block.base_fee, 0)
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
end
