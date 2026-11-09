defmodule EEVM.Handler.Execution do
  @moduledoc """
  Step 8 of the transaction pipeline — actually run the EVM.

  Two paths:

  - **Call** (`tx.to` is a 20-byte address): transfer `tx.value`, fetch the
    code at `to`, and run the interpreter against it. When `to` is an active
    precompile with no code, the precompile runs on `tx.data` instead.
  - **Create** (`tx.to` is `nil`): derive the new contract address, fail
    with all execution gas consumed if it collides with an existing account
    (EIP-684, EIP-7610), transfer `tx.value`, run `tx.data` as initcode,
    then deploy whatever the initcode
    returns as the new account's runtime code (subject to size and EIP-3541
    deposit-cost checks).

  Returns `{final_state, contract_address}` where `contract_address` is the
  newly-deployed address (CREATE path) or `nil` (call path).

  From Prague, a call to an account whose code is an EIP-7702 delegation
  designator runs the delegate's code instead, with the delegate pre-warmed.
  """

  alias EEVM.{BlockEnv, Config, Database, Delegation, HardforkConfig, Precompiles, TxEnv}
  alias EEVM.Context.Contract
  alias EEVM.Handler.PreExecution
  alias EEVM.Interpreter
  alias EEVM.Interpreter.Instructions.System.Creation
  alias EEVM.Interpreter.MachineState

  @max_code_size 24_576
  @code_deposit_gas_per_byte 200

  @no_authorizations %{authorities: MapSet.new(), refund: 0}

  @doc """
  Runs a validated transaction's EVM execution with `execution_gas` against
  `db`, in which the sender's nonce is already bumped and any EIP-7702
  authorizations are applied.

  `authorization` is the outcome of `PreExecution.apply_authorizations/3`:
  its authorities start warm and its refund is added to the transaction's
  refund counter even if execution fails.

  Returns the final machine state and the deployed contract address, or `nil`
  for a message call or a failed deployment.
  """
  @spec run_top_level(
          TxEnv.t(),
          Database.t(),
          BlockEnv.t(),
          Config.t(),
          non_neg_integer(),
          PreExecution.authorization_outcome()
        ) :: {MachineState.t(), non_neg_integer() | nil}
  def run_top_level(tx, db, block, config, execution_gas, authorization \\ @no_authorizations)

  def run_top_level(%TxEnv{to: to} = tx, db, block, config, execution_gas, authorization)
      when is_integer(to) do
    db_after_value = transfer_value(db, tx.origin, to, tx.value)
    {code, delegate} = resolve_code(db_after_value, to, config)

    # EIP-7702: a delegation to a precompile runs the (empty) delegate code,
    # not the precompile, so only an undelegated `to` qualifies.
    precompile_result =
      if delegate == nil and code == <<>> and Precompiles.precompile?(to, config),
        do: Precompiles.execute(to, tx.data, execution_gas, config)

    # A precompile's gas is deducted up front so that the interpreter's
    # finalization (refund cap, EIP-7623 calldata floor, EIP-161 cleanup)
    # sees the transaction's real gas usage.
    gas =
      case precompile_result do
        {:ok, _output, gas_used} -> execution_gas - gas_used
        _no_precompile_or_error -> execution_gas
      end

    contract_ctx =
      Contract.new(
        address: to,
        caller: tx.origin,
        callvalue: tx.value,
        calldata: tx.data
      )

    final_state =
      Interpreter.run(code,
        gas: gas,
        db: db_after_value,
        tx: tx,
        block: block,
        contract: contract_ctx,
        config: config,
        accessed_addresses:
          tx
          |> PreExecution.initial_accessed_addresses(config, contract_ctx, block)
          |> MapSet.union(authorization.authorities)
          |> MapSet.union(MapSet.new(List.wrap(delegate))),
        accessed_storage_keys: PreExecution.initial_accessed_storage_keys(tx),
        authorization_refund: authorization.refund
      )

    {apply_precompile_result(final_state, precompile_result), nil}
  end

  def run_top_level(%TxEnv{to: nil} = tx, db, block, config, execution_gas, _authorization) do
    creator = tx.origin
    pre_nonce = max(Database.get_nonce(db, creator) - 1, 0)
    new_address = derive_create_address(creator, pre_nonce)

    if Creation.address_collision?(db, new_address) do
      # EIP-684: creating over an existing account fails and consumes all of
      # the transaction's execution gas; the sender's nonce bump stands.
      {zero_gas_revert(MachineState.new(<<>>, db: db, tx: tx, block: block, config: config)), nil}
    else
      run_initcode(tx, db, block, config, execution_gas, new_address)
    end
  end

  defp apply_precompile_result(state, nil), do: state

  defp apply_precompile_result(state, {:ok, output, _gas_used}),
    do: MachineState.update_frame(state, &%{&1 | return_data: output})

  # A failed precompile is an exceptional halt: it consumes all execution gas.
  defp apply_precompile_result(state, {:error, :out_of_gas}),
    do: MachineState.halt(state, :out_of_gas)

  defp apply_precompile_result(state, {:error, reason}),
    do: MachineState.halt(state, {:error, reason})

  defp run_initcode(tx, db, block, config, execution_gas, new_address) do
    creator = tx.origin

    # The new account exists before its initcode runs, with nonce 1 from
    # EIP-161 on, so CREATEs issued by the initcode derive addresses from
    # nonce 1. It counts as created in this transaction for EIP-6780.
    db_before_init =
      db
      |> transfer_value(creator, new_address, tx.value)
      |> Database.set_nonce(
        new_address,
        if(HardforkConfig.enabled?(config.hardfork, :eip_161), do: 1, else: 0)
      )

    contract_ctx =
      Contract.new(
        address: new_address,
        caller: creator,
        callvalue: tx.value,
        calldata: <<>>
      )

    # The code deposit is part of the creation message, so it is charged
    # before the refund is settled and counts toward the refund cap.
    {deploy_result, deployed_state} =
      tx.data
      |> MachineState.new(
        gas: execution_gas,
        db: db_before_init,
        tx: tx,
        block: block,
        contract: contract_ctx,
        config: config,
        accessed_addresses:
          PreExecution.initial_accessed_addresses(tx, config, contract_ctx, block),
        accessed_storage_keys: PreExecution.initial_accessed_storage_keys(tx),
        created_addresses: MapSet.new([new_address])
      )
      |> Interpreter.run_loop()
      |> deploy_runtime_code(new_address)

    final_state = Interpreter.finalize(deployed_state, execution_gas)

    case deploy_result do
      :ok -> {final_state, new_address}
      :error -> {final_state, nil}
    end
  end

  defp resolve_code(db, address, config) do
    code = Database.get_code(db, address)

    with true <- HardforkConfig.enabled?(config.hardfork, :eip_7702),
         {:ok, delegate} <- Delegation.delegated_address(code) do
      {Database.get_code(db, delegate), delegate}
    else
      _ -> {code, nil}
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
        # If the initcode SELFDESTRUCTed, Interpreter.finalize/3 still deletes
        # the account afterwards, code included.
        updated_db = Database.put_code(state.db, new_address, runtime_code)

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
