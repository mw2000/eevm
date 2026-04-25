defmodule EEVM.TestSupport.BlockchainTestRunner do
  @moduledoc """
  Executes a single BlockchainTest case end-to-end.

  Steps:

  1. Build the pre-state database from the fixture's `pre` map and install
     any system contracts the active hardfork mandates.
  2. For each block, construct an `EEVM.Block.Header` and a list of
     `EEVM.Context.Transaction` from the parsed JSON, then run the block
     through `EEVM.Block.Processor.process_block/4` with a transaction
     executor closure that mirrors `EEVM.TestSupport.StateTestRunner` (validate
     → bump nonce → run interpreter → settle fees).
  3. Verify the resulting `state_root` matches the block's header.
  4. After every block applies cleanly, verify the final database matches
     the fixture's `postState`.

  Header validation (parent hash, timestamp monotonicity, gas-limit
  elasticity, EIP-1559 basefee, blob fields) and the InvalidBlocks negative
  path are intentionally out of scope for this commit — they land in the
  follow-ups.
  """

  alias EEVM.Block.{Header, Processor}
  alias EEVM.Context.{Block, Transaction}
  alias EEVM.Database.InMemory
  alias EEVM.Handler.Execution
  alias EEVM.SystemContracts.{BeaconRoots, BlockHashes}
  alias EEVM.TestSupport.BlockchainTestFixture.{Account, Case, TransactionFields, Withdrawal}
  alias EEVM.TestSupport.BlockchainTestFixture.Block, as: FixtureBlock
  alias EEVM.Transaction.{IntrinsicGas, Validator}
  alias EEVM.{Config, Database, HardforkConfig, StateRoot}

  @min_blob_base_fee 1

  @spec run_case(Case.t()) :: :ok | {:error, term()}
  def run_case(%Case{} = test) do
    config = Config.new(test.network)
    db = build_pre_state(test.pre, config)

    with {:ok, final_db} <- run_blocks(test.blocks, db, config) do
      verify_post_state(final_db, test.post)
    end
  end

  defp build_pre_state(pre, %Config{} = config) do
    accounts =
      Map.new(pre, fn {addr, %Account{balance: balance, nonce: nonce, code: code}} ->
        {addr, %{balance: balance, nonce: nonce, code: code}}
      end)

    storage =
      Enum.reduce(pre, %{}, fn {addr, %Account{storage: slots}}, acc ->
        if map_size(slots) == 0, do: acc, else: Map.put(acc, addr, slots)
      end)

    db = InMemory.new(accounts: accounts, storage: storage)

    db
    |> BeaconRoots.install_if_enabled(config.hardfork)
    |> BlockHashes.install_if_enabled(config.hardfork)
  end

  defp run_blocks(blocks, db, config) do
    Enum.reduce_while(blocks, {:ok, db}, fn block, {:ok, db_acc} ->
      case run_block(block, db_acc, config) do
        {:ok, new_db} -> {:cont, {:ok, new_db}}
        {:error, reason} -> {:halt, {:error, {:block_failed, block.block_number, reason}}}
      end
    end)
  end

  defp run_block(%FixtureBlock{header: nil}, _db, _config), do: {:error, :missing_block_header}

  defp run_block(%FixtureBlock{header: header} = block, db, config) do
    eevm_header = to_eevm_header(header)
    transactions = Enum.map(block.transactions, &to_context_transaction/1)

    opts = [
      tx_executor: tx_executor(config, header),
      tx_encoder: fn _tx -> <<>> end,
      system_calls: system_calls(header, config)
    ]

    case Processor.process_block(eevm_header, transactions, db, opts) do
      {:ok, result} ->
        final_db = apply_withdrawals(result.post_state_db, block.withdrawals)
        final_state_root = StateRoot.compute_state_root(final_db)

        if final_state_root == header.state_root do
          {:ok, final_db}
        else
          {:error, {:state_root_mismatch, expected: header.state_root, actual: final_state_root}}
        end

      {:error, _} = error ->
        error
    end
  end

  @gwei 1_000_000_000

  defp apply_withdrawals(db, withdrawals) do
    Enum.reduce(withdrawals, db, fn %Withdrawal{address: addr, amount: amount}, db_acc ->
      credit_balance(db_acc, addr, amount * @gwei)
    end)
  end

  defp to_eevm_header(header) do
    Header.new(
      number: header.number,
      parent_hash: header.parent_hash,
      timestamp: header.timestamp,
      coinbase: header.coinbase,
      gas_limit: header.gas_limit,
      base_fee_per_gas: header.base_fee_per_gas,
      prev_randao: header.mix_hash,
      parent_beacon_block_root: header.parent_beacon_block_root || 0,
      state_root: header.state_root,
      receipts_root: header.receipts_root,
      transactions_root: header.transactions_root,
      logs_bloom: header.logs_bloom
    )
  end

  defp to_context_transaction(%TransactionFields{} = tx) do
    Transaction.new(
      origin: tx.sender,
      nonce: tx.nonce,
      gas_limit: tx.gas_limit,
      to: tx.to,
      value: tx.value,
      data: tx.data,
      gasprice: tx.gas_price,
      max_fee_per_gas: tx.max_fee_per_gas,
      max_priority_fee_per_gas: tx.max_priority_fee_per_gas,
      max_fee_per_blob_gas: tx.max_fee_per_blob_gas,
      access_list: tx.access_list,
      blob_hashes: tx.blob_hashes,
      type: tx.type
    )
  end

  defp system_calls(header, %Config{} = config) do
    enabled_4788? = HardforkConfig.enabled?(config.hardfork, :eip_4788)
    enabled_2935? = HardforkConfig.enabled?(config.hardfork, :eip_2935)

    []
    |> maybe_append(enabled_4788?, fn db, block_ctx ->
      unwrap_system_call(BeaconRoots.commit(db, block_ctx, header.parent_beacon_block_root || 0))
    end)
    |> maybe_append(enabled_2935?, fn db, block_ctx ->
      unwrap_system_call(
        BlockHashes.commit(db, block_ctx, parent_hash_to_int(header.parent_hash))
      )
    end)
  end

  defp unwrap_system_call({:ok, %Database{} = db}), do: db
  defp unwrap_system_call({:error, _reason, %Database{} = db}), do: db

  defp parent_hash_to_int(nil), do: 0
  defp parent_hash_to_int(<<value::unsigned-big-256>>), do: value
  defp parent_hash_to_int(value) when is_integer(value), do: value

  defp maybe_append(list, false, _fun), do: list
  defp maybe_append(list, true, fun), do: list ++ [fun]

  defp tx_executor(%Config{} = config, header) do
    fn %Transaction{} = tx, %Block{} = block_ctx, db ->
      block_ctx_with_blob = put_blob_base_fee(block_ctx, header)
      execute_transaction(tx, db, block_ctx_with_blob, config)
    end
  end

  # Until full EIP-4844 fake-exponential blob-fee math lands, set blob_base_fee
  # to its post-Cancun floor of 1 wei whenever the header carries blob fields,
  # and leave it at 0 for older blocks. Non-blob fixtures don't read this.
  defp put_blob_base_fee(%Block{} = block_ctx, header) do
    blob_base_fee = if header.excess_blob_gas == nil, do: 0, else: @min_blob_base_fee
    %{block_ctx | blob_base_fee: blob_base_fee}
  end

  defp execute_transaction(%Transaction{} = tx, db, %Block{} = block_ctx, %Config{} = config) do
    case Validator.validate(tx, db, block_ctx, config.hardfork) do
      :ok ->
        db_after_nonce = Database.increment_nonce(db, tx.origin)

        with {:ok, machine} <- run_interpreter(tx, db_after_nonce, block_ctx, config),
             {:ok, finalized_db} <- finalize_fees(db_after_nonce, machine, tx, block_ctx) do
          failed = failed_status?(machine.status)
          gas_used = tx.gas_limit - machine.gas

          {:ok,
           %{
             status: if(failed, do: 0, else: 1),
             gas_used: gas_used,
             logs: if(failed, do: [], else: machine.logs),
             db: finalized_db
           }}
        end

      {:error, reason} ->
        {:error, {:validation, reason}}
    end
  end

  defp run_interpreter(%Transaction{} = tx, db, %Block{} = block_ctx, %Config{} = config) do
    intrinsic_gas = IntrinsicGas.calculate(tx)
    execution_gas = max(tx.gas_limit - intrinsic_gas, 0)
    {machine, _new_address} = Execution.run_top_level(tx, db, block_ctx, config, execution_gas)
    {:ok, machine}
  end

  defp finalize_fees(db_after_nonce, machine, tx, %Block{} = block_ctx) do
    failed = failed_status?(machine.status)
    settled = if failed, do: db_after_nonce, else: machine.db
    gas_used = tx.gas_limit - machine.gas
    apply_fees(settled, tx, block_ctx, gas_used)
  end

  defp apply_fees(db, tx, block_ctx, gas_used) do
    sender_fee = gas_used * effective_gas_price(tx, block_ctx)
    miner_reward = gas_used * miner_reward_per_gas(tx, block_ctx)

    with {:ok, debited} <- debit_balance(db, tx.origin, sender_fee) do
      {:ok, credit_balance(debited, block_ctx.coinbase, miner_reward)}
    end
  end

  defp effective_gas_price(%Transaction{type: type} = tx, %Block{} = block_ctx)
       when type in [:eip1559, :eip4844] do
    min(tx.max_fee_per_gas, block_ctx.basefee + tx.max_priority_fee_per_gas)
  end

  defp effective_gas_price(%Transaction{} = tx, _block_ctx), do: tx.gasprice

  defp miner_reward_per_gas(%Transaction{type: type} = tx, %Block{} = block_ctx)
       when type in [:eip1559, :eip4844] do
    max(effective_gas_price(tx, block_ctx) - block_ctx.basefee, 0)
  end

  defp miner_reward_per_gas(%Transaction{} = tx, %Block{} = block_ctx) do
    max(tx.gasprice - block_ctx.basefee, 0)
  end

  defp failed_status?(status) when status in [:reverted, :invalid, :out_of_gas], do: true
  defp failed_status?({:error, _}), do: true
  defp failed_status?(_), do: false

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

  defp verify_post_state(db, post) do
    Enum.find_value(post, :ok, fn {addr, %Account{} = expected} ->
      case account_diff(db, addr, expected) do
        nil -> nil
        diff -> {:error, {:post_state_mismatch, addr, diff}}
      end
    end)
  end

  defp account_diff(db, addr, %Account{} = expected) do
    actual_balance = Database.get_balance(db, addr)
    actual_nonce = Database.get_nonce(db, addr)
    actual_code = Database.get_code(db, addr)

    cond do
      actual_balance != expected.balance ->
        {:balance, expected: expected.balance, actual: actual_balance}

      actual_nonce != expected.nonce ->
        {:nonce, expected: expected.nonce, actual: actual_nonce}

      actual_code != expected.code ->
        {:code, expected: expected.code, actual: actual_code}

      storage_mismatch?(db, addr, expected.storage) ->
        {:storage, expected: expected.storage, actual: read_storage(db, addr, expected.storage)}

      true ->
        nil
    end
  end

  defp storage_mismatch?(db, addr, expected_storage) do
    Enum.any?(expected_storage, fn {slot, expected_value} ->
      Database.storage_load(db, addr, slot) != expected_value
    end)
  end

  defp read_storage(db, addr, expected_storage) do
    Map.new(expected_storage, fn {slot, _} -> {slot, Database.storage_load(db, addr, slot)} end)
  end
end
