defmodule EEVM.TestSupport.StateTestRunner do
  @moduledoc "Executes a single StateTest case and validates the post-state root and logs hash."

  alias EEVM.{Config, StateRoot}
  alias EEVM.Database.InMemory
  alias EEVM.TestSupport.{StateTestFixture, TxExecutor}
  alias EEVM.TestSupport.StateTestFixture.{Case, PostExpectation}

  @empty_logs_hash Base.decode16!(
                     "1DCC4DE8DEC75D7AAB85B567B6CCD41AD312451B948A7413F0A142FD40D49347",
                     case: :mixed
                   )

  def run_case(%Case{} = state_test, %PostExpectation{} = expectation) do
    db = InMemory.new(accounts: state_test.pre_accounts, storage: state_test.pre_storage)
    tx = StateTestFixture.build_transaction(state_test, expectation)
    block = StateTestFixture.block(state_test.env)
    config = Config.new(expectation.hardfork)

    case TxExecutor.execute(tx, db, block, config) do
      {:ok, %{db: db, machine: machine, failed?: failed?}} ->
        validate_success(
          %{
            state_root: StateRoot.compute_state_root(db),
            logs_hash: logs_hash(if(failed?, do: [], else: machine.substate.logs))
          },
          expectation
        )

      {:error, reason} ->
        validate_failure(reason, expectation)
    end
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

  defp validate_failure(_reason, %PostExpectation{expect_exception: exception})
       when is_binary(exception) and exception != "" do
    :ok
  end

  defp validate_failure(reason, _expectation), do: {:error, reason}

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
end
