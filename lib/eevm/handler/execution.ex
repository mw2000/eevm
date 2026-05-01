defmodule EEVM.Handler.Execution do
  @moduledoc """
  Step 8 of the transaction pipeline — actually run the EVM.

  Two paths:

  - **Call** (`tx.to` is a 20-byte address): transfer `tx.value`, fetch the
    code at `to`, and run the interpreter against it.
  - **Create** (`tx.to` is `nil`): derive the new contract address, transfer
    `tx.value`, run `tx.data` as initcode, then deploy whatever the initcode
    returns as the new account's runtime code (subject to size and EIP-3541
    deposit-cost checks).

  Returns `{final_state, contract_address}` where `contract_address` is the
  newly-deployed address (CREATE path) or `nil` (call path).
  """

  alias EEVM.{Config, Database, HardforkConfig}
  alias EEVM.Context.{Block, Contract, Transaction}
  alias EEVM.Handler.PreExecution
  alias EEVM.Interpreter.MachineState

  @max_code_size 24_576
  @code_deposit_gas_per_byte 200

  @spec run_top_level(Transaction.t(), Database.t(), Block.t(), Config.t(), non_neg_integer()) ::
          {MachineState.t(), non_neg_integer() | nil}
  def run_top_level(%Transaction{to: to} = tx, db, block, config, execution_gas)
      when is_integer(to) do
    db_after_value = transfer_value(db, tx.origin, to, tx.value)
    code = Database.get_code(db_after_value, to)

    contract_ctx =
      Contract.new(
        address: to,
        caller: tx.origin,
        callvalue: tx.value,
        calldata: tx.data
      )

    final_state =
      EEVM.execute(code,
        gas: execution_gas,
        db: db_after_value,
        tx: tx,
        block: block,
        contract: contract_ctx,
        config: config,
        accessed_addresses:
          PreExecution.initial_accessed_addresses(tx, config, contract_ctx, block),
        accessed_storage_keys: PreExecution.initial_accessed_storage_keys(tx)
      )

    {final_state, nil}
  end

  def run_top_level(%Transaction{to: nil} = tx, db, block, config, execution_gas) do
    creator = tx.origin
    pre_nonce = max(Database.get_nonce(db, creator) - 1, 0)
    new_address = derive_create_address(creator, pre_nonce)

    db_after_value = transfer_value(db, creator, new_address, tx.value)

    contract_ctx =
      Contract.new(
        address: new_address,
        caller: creator,
        callvalue: tx.value,
        calldata: <<>>
      )

    final_state =
      EEVM.execute(tx.data,
        gas: execution_gas,
        db: db_after_value,
        tx: tx,
        block: block,
        contract: contract_ctx,
        config: config,
        accessed_addresses:
          PreExecution.initial_accessed_addresses(tx, config, contract_ctx, block),
        accessed_storage_keys: PreExecution.initial_accessed_storage_keys(tx)
      )

    case deploy_runtime_code(final_state, new_address) do
      {:ok, deployed_state} -> {deployed_state, new_address}
      {:error, deployed_state} -> {deployed_state, nil}
    end
  end

  defp deploy_runtime_code(%MachineState{status: :stopped} = state, new_address) do
    runtime_code = state.frame.return_data
    size = byte_size(runtime_code)
    deposit_cost = size * @code_deposit_gas_per_byte

    cond do
      size > @max_code_size ->
        {:error, zero_gas_revert(state)}

      state.frame.gas < deposit_cost ->
        {:error, zero_gas_revert(state)}

      size > 0 and :binary.first(runtime_code) == 0xEF and
          HardforkConfig.enabled?(state.env.config.hardfork, :eip_3541) ->
        {:error, zero_gas_revert(state)}

      true ->
        updated_db =
          state.db
          |> Database.put_code(new_address, runtime_code)
          |> Database.set_nonce(new_address, 1)

        deducted = MachineState.update_frame(state, &%{&1 | gas: &1.gas - deposit_cost})
        {:ok, %{deducted | db: updated_db}}
    end
  end

  defp deploy_runtime_code(state, _new_address), do: {:error, state}

  defp zero_gas_revert(state) do
    state
    |> MachineState.update_frame(&%{&1 | gas: 0})
    |> Map.put(:status, :reverted)
  end

  defp transfer_value(%Database{} = db, _from, _to, 0), do: db

  defp transfer_value(%Database{} = db, from, to, value) do
    case Database.transfer(db, from, to, value) do
      {:ok, new_db} -> new_db
      # Upfront charge already verified the sender's balance covers `value`;
      # this branch only fires if an external database rejects the transfer.
      {:error, :insufficient_balance} -> db
    end
  end

  # CREATE address: keccak(rlp([sender, nonce]))[-20:]
  defp derive_create_address(sender, nonce) do
    sender_bytes = <<sender::unsigned-big-160>>
    payload = rlp_encode_list([rlp_encode_bytes(sender_bytes), rlp_encode_integer(nonce)])
    <<_::binary-size(12), address::unsigned-big-160>> = ExKeccak.hash_256(payload)
    address
  end

  defp rlp_encode_integer(0), do: <<0x80>>

  defp rlp_encode_integer(value) when is_integer(value) and value > 0 do
    value
    |> :binary.encode_unsigned()
    |> rlp_encode_bytes()
  end

  defp rlp_encode_bytes(<<byte>>) when byte < 0x80, do: <<byte>>

  defp rlp_encode_bytes(bytes) do
    length = byte_size(bytes)

    if length <= 55 do
      <<0x80 + length, bytes::binary>>
    else
      length_bytes = :binary.encode_unsigned(length)
      <<0xB7 + byte_size(length_bytes), length_bytes::binary, bytes::binary>>
    end
  end

  defp rlp_encode_list(items) do
    payload = IO.iodata_to_binary(items)
    length = byte_size(payload)

    if length <= 55 do
      <<0xC0 + length, payload::binary>>
    else
      length_bytes = :binary.encode_unsigned(length)
      <<0xF7 + byte_size(length_bytes), length_bytes::binary, payload::binary>>
    end
  end
end
