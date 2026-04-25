defmodule EEVM.Transaction.Executor do
  @moduledoc """
  End-to-end transaction execution pipeline.

  ## EVM Concepts

  A signed transaction is not a single operation — it is a sequence of well-defined
  steps the client must perform against current world state. This module implements
  those steps in order, using the primitives already provided by the rest of the
  codebase:

  1. **Decode** — wire-format RLP bytes are turned into a typed `EEVM.Transaction`
     envelope struct. Callers that already have a struct can pass it directly.
  2. **Recover sender** — secp256k1 ecrecover on the typed signing hash yields
     the transaction originator.
  3. **Validate** — intrinsic gas, nonce, balance, EOA sender, EIP-1559 fee
     constraints, and blob/initcode size rules are checked via
     `EEVM.Transaction.Validator`.
  4. **Charge upfront gas** — `gas_limit * effective_gas_price + value` must fit
     in the sender's balance. For EIP-1559 the up-front check uses
     `max_fee_per_gas`, while the actual price charged is
     `min(max_fee_per_gas, base_fee + max_priority_fee_per_gas)`.
  5. **Calculate intrinsic gas** — `EEVM.Transaction.IntrinsicGas.calculate/1`
     returns the base 21,000 + per-byte + access-list + initcode components.
     The gas available to the EVM is `tx.gas_limit - intrinsic`.
  6. **Set up context** — `EEVM.Context.Transaction`, `Block`, and `Contract` are
     populated so opcode implementations (ORIGIN, CALLER, CALLVALUE, CHAINID, …)
     read consistent values.
  7. **Pre-warm access set** — EIP-2929/EIP-3651 pre-warming is done by
     `EEVM.MachineState.new/2`; additional access-list entries are merged into
     `accessed_addresses` and `accessed_storage_keys` before execution.
  8. **Execute** — a normal call hands off to `EEVM.Executor.run/2`. A contract
     deployment (`to == nil`) runs the initcode, deploys the returned runtime
     code at a CREATE-derived address, and charges code deposit cost.
  9. **Apply refund** — `min(refund, gas_used / 5)` is added back; already
     performed by `EEVM.Executor.run/2`'s `apply_refund/2` helper.
  10. **Settle fees** — the sender is debited `gas_used * effective_gas_price`;
      the coinbase is credited `gas_used * (effective_gas_price - base_fee)`.
  11. **Build receipt** — status, cumulative gas, logs, logs bloom.

  ## Elixir Learning Notes

  - The pipeline is written as a `with` chain — each step returns `{:ok, …}`
    or `{:error, reason}`, and the chain short-circuits on the first failure.
  - The sender is represented two ways: as a 20-byte binary (from the wire
    and from `Signer.recover_sender/2`) and as an integer (inside the
    `EEVM.Context.Transaction` struct and the `EEVM.Database` key space).
    A single `decode_address/1` helper does the conversion.
  - Contract creation derives the new address via `keccak(rlp([sender, nonce]))`
    — the same algorithm used by `CREATE` inside the EVM, kept separate here
    so the top-level pipeline does not depend on the opcode module's internals.
  """

  alias EEVM.{Bloom, Config, Database, HardforkConfig, MachineState, TransactionResult}
  alias EEVM.Context.{Block, Contract, Transaction}

  alias EEVM.Transaction.{
    AccessList,
    Blob,
    Envelope,
    FeeMarket,
    IntrinsicGas,
    Legacy,
    SetCode,
    Signer,
    Validator
  }

  @type wire_tx ::
          Legacy.t() | AccessList.t() | FeeMarket.t() | Blob.t() | SetCode.t() | binary()

  @type opts :: [
          hardfork: HardforkConfig.spec_id(),
          chain_id: non_neg_integer(),
          config: Config.t()
        ]

  @default_chain_id 1
  @default_hardfork :cancun
  @max_code_size 24_576
  @code_deposit_gas_per_byte 200

  @doc """
  Executes a single transaction end-to-end.

  `tx_or_bytes` may be either raw wire bytes (legacy RLP or a typed envelope
  prefix + RLP) or one of the typed `EEVM.Transaction.*` structs.

  ## Options

  - `:chain_id` — chain id used when recovering the sender (default: `1`).
  - `:hardfork` — hardfork spec id governing gas rules and EIP activation
    (default: `:cancun`).
  - `:config` — fully assembled `EEVM.Config` to use instead of deriving one
    from `:hardfork`. Takes precedence when both are provided.

  ## Returns

  - `{:ok, %EEVM.TransactionResult{}}` on any transaction that made it past
    validation — including reverted ones. Inspect `result.status` to tell
    success from revert.
  - `{:error, reason}` when decoding, sender recovery, validation, or upfront
    balance charging fail. The database is returned unchanged to the caller
    in this case (the `TransactionResult.post_state_db` is not built).
  """
  @spec execute(wire_tx(), Block.t(), Database.t(), opts()) ::
          {:ok, TransactionResult.t()} | {:error, atom()}
  def execute(tx_or_bytes, %Block{} = block, %Database{} = db, opts \\ []) do
    chain_id = Keyword.get(opts, :chain_id, @default_chain_id)
    config = resolve_config(opts)

    with {:ok, wire_tx} <- ensure_decoded(tx_or_bytes),
         {:ok, sender_bytes} <- Signer.recover_sender(wire_tx, chain_id),
         {:ok, tx_ctx} <- build_tx_context(wire_tx, sender_bytes),
         :ok <- Validator.validate(tx_ctx, db, block, config.hardfork),
         {:ok, db_after_upfront} <- charge_upfront(db, tx_ctx, block) do
      run_and_finalize(tx_ctx, sender_bytes, db_after_upfront, block, config)
    end
  end

  # ---------------------------------------------------------------------------
  # Decoding
  # ---------------------------------------------------------------------------

  defp ensure_decoded(%Legacy{} = tx), do: {:ok, tx}
  defp ensure_decoded(%AccessList{} = tx), do: {:ok, tx}
  defp ensure_decoded(%FeeMarket{} = tx), do: {:ok, tx}
  defp ensure_decoded(%Blob{} = tx), do: {:ok, tx}
  defp ensure_decoded(%SetCode{} = tx), do: {:ok, tx}
  defp ensure_decoded(bytes) when is_binary(bytes), do: Envelope.decode(bytes)
  defp ensure_decoded(_), do: {:error, :invalid_transaction_input}

  defp resolve_config(opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, %Config{} = config} ->
        config

      _ ->
        Config.new(Keyword.get(opts, :hardfork, @default_hardfork))
    end
  end

  # ---------------------------------------------------------------------------
  # Wire tx -> Context.Transaction
  # ---------------------------------------------------------------------------

  defp build_tx_context(%Legacy{} = tx, sender_bytes) do
    {:ok,
     Transaction.new(
       origin: decode_address(sender_bytes),
       nonce: tx.nonce,
       gas_limit: tx.gas_limit,
       to: optional_address(tx.to),
       value: tx.value,
       data: tx.data,
       gasprice: tx.gas_price,
       max_fee_per_gas: tx.gas_price,
       max_priority_fee_per_gas: tx.gas_price,
       access_list: [],
       blob_hashes: [],
       max_fee_per_blob_gas: 0,
       type: :legacy
     )}
  end

  defp build_tx_context(%AccessList{} = tx, sender_bytes) do
    {:ok,
     Transaction.new(
       origin: decode_address(sender_bytes),
       nonce: tx.nonce,
       gas_limit: tx.gas_limit,
       to: optional_address(tx.to),
       value: tx.value,
       data: tx.data,
       gasprice: tx.gas_price,
       max_fee_per_gas: tx.gas_price,
       max_priority_fee_per_gas: tx.gas_price,
       access_list: decode_access_list(tx.access_list),
       blob_hashes: [],
       max_fee_per_blob_gas: 0,
       type: :eip2930
     )}
  end

  defp build_tx_context(%FeeMarket{} = tx, sender_bytes) do
    {:ok,
     Transaction.new(
       origin: decode_address(sender_bytes),
       nonce: tx.nonce,
       gas_limit: tx.gas_limit,
       to: optional_address(tx.to),
       value: tx.value,
       data: tx.data,
       gasprice: 0,
       max_fee_per_gas: tx.max_fee_per_gas,
       max_priority_fee_per_gas: tx.max_priority_fee_per_gas,
       access_list: decode_access_list(tx.access_list),
       blob_hashes: [],
       max_fee_per_blob_gas: 0,
       type: :eip1559
     )}
  end

  defp build_tx_context(%Blob{} = tx, sender_bytes) do
    {:ok,
     Transaction.new(
       origin: decode_address(sender_bytes),
       nonce: tx.nonce,
       gas_limit: tx.gas_limit,
       to: optional_address(tx.to),
       value: tx.value,
       data: tx.data,
       gasprice: 0,
       max_fee_per_gas: tx.max_fee_per_gas,
       max_priority_fee_per_gas: tx.max_priority_fee_per_gas,
       access_list: decode_access_list(tx.access_list),
       blob_hashes: Enum.map(tx.blob_versioned_hashes, &:binary.decode_unsigned/1),
       max_fee_per_blob_gas: tx.max_fee_per_blob_gas,
       type: :eip4844
     )}
  end

  defp build_tx_context(%SetCode{}, _sender_bytes), do: {:error, :set_code_not_supported}

  defp optional_address(nil), do: nil
  defp optional_address(<<>>), do: nil

  defp optional_address(bytes) when is_binary(bytes) and byte_size(bytes) == 20,
    do: :binary.decode_unsigned(bytes)

  defp decode_address(bytes) when is_binary(bytes) and byte_size(bytes) == 20,
    do: :binary.decode_unsigned(bytes)

  defp decode_access_list(access_list) do
    Enum.map(access_list, fn {address, slots} ->
      {:binary.decode_unsigned(address), Enum.map(slots, &:binary.decode_unsigned/1)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Upfront balance charge (step 4)
  # ---------------------------------------------------------------------------

  # Validate the sender can pay `gas_limit * max_price + value`, then debit
  # the *gas* portion only. `value` is moved separately by `transfer_value/4`
  # at the moment the call frame is set up, so we must not deduct it twice.
  defp charge_upfront(%Database{} = db, %Transaction{} = tx, %Block{} = block) do
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

  defp gas_upfront(%Transaction{type: type} = tx) when type in [:eip1559, :eip4844] do
    tx.gas_limit * tx.max_fee_per_gas
  end

  defp gas_upfront(%Transaction{} = tx), do: tx.gas_limit * tx.gasprice

  defp effective_gas_price(%Transaction{type: type} = tx, %Block{} = block)
       when type in [:eip1559, :eip4844] do
    min(tx.max_fee_per_gas, block.basefee + tx.max_priority_fee_per_gas)
  end

  defp effective_gas_price(%Transaction{} = tx, %Block{}), do: tx.gasprice

  # ---------------------------------------------------------------------------
  # Execution + finalization (steps 5–11)
  # ---------------------------------------------------------------------------

  defp run_and_finalize(
         %Transaction{} = tx,
         sender_bytes,
         %Database{} = db_after_upfront,
         %Block{} = block,
         %Config{} = config
       ) do
    intrinsic = IntrinsicGas.calculate(tx)

    if tx.gas_limit < intrinsic do
      {:error, :intrinsic_gas_too_low}
    else
      execution_gas = tx.gas_limit - intrinsic
      db_nonce_bumped = Database.increment_nonce(db_after_upfront, tx.origin)

      {final_state, contract_address} =
        execute_top_level(tx, db_nonce_bumped, block, config, execution_gas)

      gas_used = tx.gas_limit - final_state.gas
      effective_price = effective_gas_price(tx, block)

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

      gas_refunded = max(final_state.gas, 0)

      {:ok,
       %TransactionResult{
         status: status,
         gas_used: gas_used,
         gas_refunded: gas_refunded,
         sender: decode_address(sender_bytes),
         logs: logs,
         logs_bloom: logs_bloom,
         receipt: receipt,
         post_state_db: coinbase_credited_db,
         return_data: if(status == :success, do: final_state.return_data, else: <<>>),
         contract_address: if(status == :success, do: contract_address, else: nil)
       }}
    end
  end

  # Execute a call-like transaction (step 8, call path).
  defp execute_top_level(%Transaction{to: to} = tx, db, block, config, execution_gas)
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

    accessed_addresses = initial_accessed_addresses(tx, config, contract_ctx, block)
    accessed_storage_keys = initial_accessed_storage_keys(tx)

    final_state =
      EEVM.execute(code,
        gas: execution_gas,
        db: db_after_value,
        tx: tx,
        block: block,
        contract: contract_ctx,
        config: config,
        accessed_addresses: accessed_addresses,
        accessed_storage_keys: accessed_storage_keys
      )

    {final_state, nil}
  end

  # Execute a CREATE-style top-level transaction (step 8, create path).
  defp execute_top_level(%Transaction{to: nil} = tx, db, block, config, execution_gas) do
    creator = tx.origin
    # The nonce bump has already happened; derive the contract address from the
    # nonce value *before* that bump (the sender's pre-tx nonce).
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

    accessed_addresses = initial_accessed_addresses(tx, config, contract_ctx, block)
    accessed_storage_keys = initial_accessed_storage_keys(tx)

    final_state =
      EEVM.execute(tx.data,
        gas: execution_gas,
        db: db_after_value,
        tx: tx,
        block: block,
        contract: contract_ctx,
        config: config,
        accessed_addresses: accessed_addresses,
        accessed_storage_keys: accessed_storage_keys
      )

    case deploy_runtime_code(final_state, new_address) do
      {:ok, deployed_state} -> {deployed_state, new_address}
      {:error, deployed_state} -> {deployed_state, nil}
    end
  end

  defp deploy_runtime_code(%MachineState{status: :stopped} = state, new_address) do
    runtime_code = state.return_data
    size = byte_size(runtime_code)
    deposit_cost = size * @code_deposit_gas_per_byte

    cond do
      size > @max_code_size ->
        {:error, %{state | gas: 0, status: :reverted}}

      state.gas < deposit_cost ->
        {:error, %{state | gas: 0, status: :reverted}}

      size > 0 and :binary.first(runtime_code) == 0xEF and
          HardforkConfig.enabled?(state.config.hardfork, :eip_3541) ->
        {:error, %{state | gas: 0, status: :reverted}}

      true ->
        updated_db =
          state.db
          |> Database.put_code(new_address, runtime_code)
          |> Database.set_nonce(new_address, 1)

        {:ok, %{state | db: updated_db, gas: state.gas - deposit_cost}}
    end
  end

  defp deploy_runtime_code(state, _new_address), do: {:error, state}

  defp transfer_value(%Database{} = db, _from, _to, 0), do: db

  defp transfer_value(%Database{} = db, from, to, value) do
    case Database.transfer(db, from, to, value) do
      {:ok, new_db} -> new_db
      # Upfront charge already ensured the sender has balance for `value`;
      # hit this branch only if an external database rejects the transfer.
      {:error, :insufficient_balance} -> db
    end
  end

  # ---------------------------------------------------------------------------
  # Access list pre-warming
  # ---------------------------------------------------------------------------

  defp initial_accessed_addresses(tx, config, contract_ctx, block) do
    base =
      MapSet.new()
      |> MapSet.put(contract_ctx.address)
      |> MapSet.put(contract_ctx.caller)
      |> MapSet.put(tx.origin)
      |> MapSet.put(block.coinbase)
      |> then(fn set ->
        Enum.reduce(EEVM.Precompiles.precompile_addresses(config), set, &MapSet.put(&2, &1))
      end)

    Enum.reduce(tx.access_list, base, fn {address, _slots}, acc ->
      MapSet.put(acc, address)
    end)
  end

  defp initial_accessed_storage_keys(tx) do
    Enum.reduce(tx.access_list, MapSet.new(), fn {address, slots}, acc ->
      Enum.reduce(slots, acc, fn slot, inner -> MapSet.put(inner, {address, slot}) end)
    end)
  end

  # ---------------------------------------------------------------------------
  # State settlement (steps 9–10)
  # ---------------------------------------------------------------------------

  # The sender was debited `gas_limit * max_price` upfront. They actually owe
  # `gas_used * effective_price`. Refund the difference to the appropriate db:
  #
  # - On success, the executor's db already reflects every side effect, so we
  #   credit there.
  # - On revert / out-of-gas / invalid, EVM-side mutations are dropped — we
  #   credit the post-upfront, post-nonce-bump db instead.
  #
  # `effective_price <= max_price`, so this term is always non-negative; for
  # legacy transactions where max == effective the refund collapses to the
  # unused-gas refund (`state.gas * gas_price`).
  defp settle_state(%MachineState{status: status}, db_nonce_bumped, tx, gas_used, effective_price)
       when status in [:reverted, :invalid, :out_of_gas] or is_tuple(status) do
    refund_amount = gas_upfront(tx) - gas_used * effective_price
    credit_sender(db_nonce_bumped, tx.origin, refund_amount)
  end

  defp settle_state(%MachineState{} = state, _db_nonce_bumped, tx, gas_used, effective_price) do
    refund_amount = gas_upfront(tx) - gas_used * effective_price
    credit_sender(state.db, tx.origin, refund_amount)
  end

  defp credit_coinbase(%Database{} = db, %Block{}, _tx, 0, _price), do: db

  defp credit_coinbase(%Database{} = db, %Block{} = block, %Transaction{} = tx, gas_used, _price) do
    priority_per_gas = max(effective_gas_price(tx, block) - block.basefee, 0)
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

  # ---------------------------------------------------------------------------
  # CREATE address derivation (keccak(rlp([sender, nonce]))[-20:])
  # ---------------------------------------------------------------------------

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
