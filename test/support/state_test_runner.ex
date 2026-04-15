defmodule EEVM.TestSupport.StateTestRunner do
  @moduledoc "Executes a single StateTest case and validates the post-state root and logs hash."

  alias EEVM.{Config, Database, StateRoot}
  alias EEVM.Context.Contract
  alias EEVM.Database.InMemory
  alias EEVM.TestSupport.StateTestFixture
  alias EEVM.TestSupport.StateTestFixture.{Case, PostExpectation}
  alias EEVM.Transaction.{IntrinsicGas, Validator}

  @empty_logs_hash Base.decode16!(
                     "1DCC4DE8DEC75D7AAB85B567B6CCD41AD312451B948A7413F0A142FD40D49347",
                     case: :mixed
                   )

  def run_case(%Case{} = state_test, %PostExpectation{} = expectation) do
    db = InMemory.new(accounts: state_test.pre_accounts, storage: state_test.pre_storage)
    tx = StateTestFixture.build_transaction(state_test, expectation)
    block = StateTestFixture.block(state_test.env)

    case execute_transaction(tx, db, block, expectation.hardfork) do
      {:ok, result} -> validate_success(result, expectation)
      {:error, reason} -> validate_failure(reason, expectation)
    end
  end

  defp execute_transaction(tx, db, block, hardfork) do
    case Validator.validate(tx, db, block, Config.new(hardfork).hardfork) do
      :ok ->
        db_after_nonce = Database.increment_nonce(db, tx.origin)

        with {:ok, db_for_execution} <- apply_top_level_value(db_after_nonce, tx),
             {:ok, machine} <- run_top_level(tx, db_for_execution, block, hardfork),
             {:ok, finalized_db} <- finalize_fees(db_after_nonce, machine, tx, block) do
          failed = failed_status?(machine.status)

          {:ok,
           %{
             state_root: StateRoot.compute_state_root(finalized_db),
             logs_hash: logs_hash(if(failed, do: [], else: machine.logs)),
             output: if(failed, do: <<>>, else: machine.return_data),
             status: machine.status,
             gas_used: tx.gas_limit - machine.gas,
             db: finalized_db
           }}
        end

      {:error, reason} ->
        {:error, {:validation, reason}}
    end
  end

  defp run_top_level(%{to: nil}, _db, _block, _hardfork), do: {:error, :unsupported_creation}

  defp run_top_level(tx, db, block, hardfork) do
    intrinsic_gas = IntrinsicGas.calculate(tx)
    execution_gas = tx.gas_limit - intrinsic_gas
    code = Database.get_code(db, tx.to)

    machine =
      EEVM.execute(code,
        gas: execution_gas,
        db: db,
        tx: tx,
        block: block,
        contract:
          Contract.new(address: tx.to, caller: tx.origin, callvalue: tx.value, calldata: tx.data),
        config: Config.new(hardfork)
      )

    {:ok, machine}
  end

  defp apply_top_level_value(db, %{to: nil}), do: {:ok, db}
  defp apply_top_level_value(db, %{value: 0}), do: {:ok, db}

  defp apply_top_level_value(db, %{origin: origin, to: to, value: value}),
    do: Database.transfer(db, origin, to, value)

  defp settle_state(db_after_nonce, _machine, true), do: db_after_nonce
  defp settle_state(_db_after_nonce, machine, false), do: machine.db

  defp finalize_fees(db_after_nonce, machine, tx, block) do
    failed = failed_status?(machine.status)
    settled_db = settle_state(db_after_nonce, machine, failed)
    gas_used = tx.gas_limit - machine.gas
    apply_fees(settled_db, tx, block, gas_used)
  end

  defp apply_fees(db, tx, block, gas_used) do
    sender_fee = gas_used * effective_gas_price(tx, block)
    miner_reward = gas_used * miner_reward_per_gas(tx, block)

    with {:ok, debited_db} <- debit_balance(db, tx.origin, sender_fee) do
      {:ok, credit_balance(debited_db, block.coinbase, miner_reward)}
    end
  end

  defp effective_gas_price(%{type: type} = tx, block) when type in [:eip1559, :eip4844] do
    min(tx.max_fee_per_gas, block.basefee + tx.max_priority_fee_per_gas)
  end

  defp effective_gas_price(tx, _block), do: tx.gasprice

  defp miner_reward_per_gas(%{type: type} = tx, block) when type in [:eip1559, :eip4844] do
    max(effective_gas_price(tx, block) - block.basefee, 0)
  end

  defp miner_reward_per_gas(tx, block) do
    max(tx.gasprice - block.basefee, 0)
  end

  defp validate_success(_result, %PostExpectation{expect_exception: exception})
       when is_binary(exception) and exception != "" do
    {:error, {:expected_exception, exception}}
  end

  defp validate_success(result, %PostExpectation{} = expectation) do
    cond do
      result.state_root != expectation.hash ->
        {:error, {:state_root_mismatch, result.state_root, expectation.hash}}

      result.logs_hash != expectation.logs ->
        {:error, {:logs_hash_mismatch, result.logs_hash, expectation.logs}}

      true ->
        :ok
    end
  end

  defp validate_failure(reason, %PostExpectation{expect_exception: exception})
       when is_binary(exception) and exception != "" do
    _ = reason
    :ok
  end

  defp validate_failure(reason, _expectation), do: {:error, reason}

  defp failed_status?(status) when status in [:reverted, :invalid, :out_of_gas], do: true
  defp failed_status?({:error, _}), do: true
  defp failed_status?(_), do: false

  defp logs_hash([]), do: @empty_logs_hash

  defp logs_hash(logs) do
    logs
    |> Enum.map(fn %{address: address, topics: topics, data: data} ->
      [encode_uint(address, 20), Enum.map(topics, &encode_uint(&1, 32)), data]
    end)
    |> ExRLP.encode()
    |> ExKeccak.hash_256()
  end

  defp encode_uint(value, bytes) when is_integer(value) and value >= 0 do
    encoded = :binary.encode_unsigned(value)

    cond do
      byte_size(encoded) == bytes -> encoded
      byte_size(encoded) < bytes -> <<0::size((bytes - byte_size(encoded)) * 8), encoded::binary>>
      true -> binary_part(encoded, byte_size(encoded) - bytes, bytes)
    end
  end

  defp debit_balance(db, _address, 0), do: {:ok, db}

  defp debit_balance(db, address, amount) do
    current_balance = Database.get_balance(db, address)

    if current_balance < amount do
      {:error, :insufficient_balance}
    else
      {:ok, Database.set_balance(db, address, current_balance - amount)}
    end
  end

  defp credit_balance(db, _address, 0), do: db

  defp credit_balance(db, address, amount) do
    Database.set_balance(db, address, Database.get_balance(db, address) + amount)
  end
end
