defmodule EEVM.Block.Processor do
  @moduledoc """
  End-to-end block execution: system calls, then transactions, then header
  commitments.

  Pipeline:

  1. Reject if the sum of `tx.gas_limit` exceeds `header.gas_limit`.
  2. Apply each `:system_calls` hook (EIP-4788 beacon roots, EIP-2935 block
     hashes) against `pre_state_db` in order.
  3. Fold transactions left-to-right; each call sees the post-state of every
     prior tx and produces a receipt whose `cumulative_gas_used` is the
     running total. A failing tx halts the block and returns the index.
  4. Build `%Result{}` with `state_root`, `transactions_root`, `receipts_root`,
     aggregated `logs_bloom`, and total `gas_used`.

  Callers inject `:tx_executor` (`(tx, %Context.Block{}, %Database{}) ->
  {:ok, %{status, gas_used, logs, db}} | {:error, reason}`), an optional
  `:system_calls` list, and an optional `:tx_encoder` (defaults to
  `EEVM.Transaction.Envelope.encode/1`) for the transactions trie. No
  optimistic rollback — a tx failure leaves the post-state at the last
  successful tx.
  """

  alias EEVM.Block.{Bloom, Header, Receipt, Result}
  alias EEVM.{Database, StateRoot}
  alias EEVM.Context.Block, as: BlockCtx
  alias EEVM.MPT.Trie
  alias EEVM.Transaction.Envelope

  @type tx_result :: %{
          required(:status) => 0 | 1,
          required(:gas_used) => non_neg_integer(),
          required(:logs) => [Bloom.log_entry()],
          required(:db) => Database.t()
        }

  @type tx_executor :: (term(), BlockCtx.t(), Database.t() ->
                          {:ok, tx_result()} | {:error, term()})

  @type system_call :: (Database.t(), BlockCtx.t() -> Database.t())

  @type tx_encoder :: (term() -> binary())

  @type process_opts :: [
          tx_executor: tx_executor(),
          system_calls: [system_call()],
          tx_encoder: tx_encoder(),
          hardfork: atom() | nil
        ]

  @type process_error ::
          :block_gas_limit_exceeded
          | {:tx_failed, non_neg_integer(), term()}

  @doc """
  Execute every phase of the block and produce a `%EEVM.Block.Result{}`.

  The caller owns `pre_state_db` and must pass an injected `:tx_executor`.
  See the module doc for the full option list.

  Returns:

  - `{:ok, %Result{}}` on success.
  - `{:error, :block_gas_limit_exceeded}` when `sum(tx.gas_limit)` exceeds
    `header.gas_limit`.
  - `{:error, {:tx_failed, index, reason}}` when the injected executor
    rejects a transaction. `index` is 0-based in `transactions` order.
  """
  @spec process_block(Header.t(), [term()], Database.t(), process_opts()) ::
          {:ok, Result.t()} | {:error, process_error()}
  def process_block(%Header{} = header, transactions, %Database{} = pre_state_db, opts)
      when is_list(transactions) and is_list(opts) do
    tx_executor = fetch_executor!(opts)
    system_calls = Keyword.get(opts, :system_calls, [])
    tx_encoder = Keyword.get(opts, :tx_encoder, &Envelope.encode/1)

    block_ctx = to_block_ctx(header)

    with :ok <- check_block_gas_limit(header, transactions) do
      db_after_system = apply_system_calls(pre_state_db, block_ctx, system_calls)

      case execute_transactions(transactions, block_ctx, db_after_system, tx_executor) do
        {:ok, receipts, post_db, gas_used} ->
          {:ok, build_result(post_db, receipts, transactions, gas_used, tx_encoder)}

        {:error, _} = error ->
          error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 1 — block-level gas check
  # ---------------------------------------------------------------------------

  @spec check_block_gas_limit(Header.t(), [term()]) :: :ok | {:error, :block_gas_limit_exceeded}
  defp check_block_gas_limit(%Header{gas_limit: block_gas_limit}, transactions) do
    declared = Enum.reduce(transactions, 0, fn tx, acc -> acc + tx_gas_limit(tx) end)

    if declared > block_gas_limit do
      {:error, :block_gas_limit_exceeded}
    else
      :ok
    end
  end

  # Works for any struct or map carrying a `:gas_limit` field — that's every
  # envelope struct and every plausible test double. Anything without the
  # field counts as zero gas so callers aren't forced to pad stubs.
  @spec tx_gas_limit(term()) :: non_neg_integer()
  defp tx_gas_limit(%{gas_limit: gas_limit}) when is_integer(gas_limit) and gas_limit >= 0,
    do: gas_limit

  defp tx_gas_limit(_tx), do: 0

  # ---------------------------------------------------------------------------
  # Phase 2 — system calls (EIP-4788 / EIP-2935 etc. inject here)
  # ---------------------------------------------------------------------------

  @spec apply_system_calls(Database.t(), BlockCtx.t(), [system_call()]) :: Database.t()
  defp apply_system_calls(db, block_ctx, system_calls) do
    Enum.reduce(system_calls, db, fn hook, db_acc -> hook.(db_acc, block_ctx) end)
  end

  # ---------------------------------------------------------------------------
  # Phase 3 — transaction fold with cumulative gas tracking
  # ---------------------------------------------------------------------------

  @spec execute_transactions([term()], BlockCtx.t(), Database.t(), tx_executor()) ::
          {:ok, [Receipt.t()], Database.t(), non_neg_integer()}
          | {:error, {:tx_failed, non_neg_integer(), term()}}
  defp execute_transactions(transactions, block_ctx, db, tx_executor) do
    initial = {[], db, 0, 0}

    transactions
    |> Enum.reduce_while(initial, fn tx, {receipts, db_acc, cumulative_gas, index} ->
      case tx_executor.(tx, block_ctx, db_acc) do
        {:ok, %{status: status, gas_used: gas_used, logs: logs, db: new_db}} ->
          new_cumulative = cumulative_gas + gas_used

          receipt = %Receipt{
            status: status,
            cumulative_gas_used: new_cumulative,
            logs: logs,
            logs_bloom: Bloom.from_logs(logs)
          }

          {:cont, {[receipt | receipts], new_db, new_cumulative, index + 1}}

        {:error, reason} ->
          {:halt, {:error, {:tx_failed, index, reason}}}
      end
    end)
    |> case do
      {:error, _} = error ->
        error

      {receipts, post_db, cumulative_gas, _index} ->
        {:ok, Enum.reverse(receipts), post_db, cumulative_gas}
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 4 — commitments
  # ---------------------------------------------------------------------------

  @spec build_result(
          Database.t(),
          [Receipt.t()],
          [term()],
          non_neg_integer(),
          tx_encoder()
        ) :: Result.t()
  defp build_result(post_db, receipts, transactions, gas_used, tx_encoder) do
    %Result{
      post_state_db: post_db,
      receipts: receipts,
      state_root: StateRoot.compute_state_root(post_db),
      receipts_root: compute_receipts_root(receipts),
      transactions_root: compute_transactions_root(transactions, tx_encoder),
      logs_bloom: aggregate_logs_bloom(receipts),
      gas_used: gas_used
    }
  end

  @spec compute_receipts_root([Receipt.t()]) :: binary()
  defp compute_receipts_root(receipts) do
    receipts
    |> Enum.with_index()
    |> Enum.map(fn {receipt, index} -> {ExRLP.encode(index), encode_receipt(receipt)} end)
    |> Trie.root_hash()
  end

  @spec compute_transactions_root([term()], tx_encoder()) :: binary()
  defp compute_transactions_root(transactions, tx_encoder) do
    transactions
    |> Enum.with_index()
    |> Enum.map(fn {tx, index} -> {ExRLP.encode(index), tx_encoder.(tx)} end)
    |> Trie.root_hash()
  end

  @spec aggregate_logs_bloom([Receipt.t()]) :: Bloom.t()
  defp aggregate_logs_bloom(receipts) do
    Enum.reduce(receipts, Bloom.empty(), fn %Receipt{logs_bloom: bloom}, acc ->
      Bloom.merge(acc, bloom)
    end)
  end

  # Byzantium-and-later receipt layout: [status, cumulativeGasUsed, bloom, logs].
  @spec encode_receipt(Receipt.t()) :: binary()
  defp encode_receipt(%Receipt{} = receipt) do
    encoded_logs =
      Enum.map(receipt.logs, fn %{address: address, topics: topics, data: data} ->
        [<<address::unsigned-big-160>>, Enum.map(topics, &<<&1::unsigned-big-256>>), data]
      end)

    ExRLP.encode([receipt.status, receipt.cumulative_gas_used, receipt.logs_bloom, encoded_logs])
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @spec fetch_executor!(process_opts()) :: tx_executor()
  defp fetch_executor!(opts) do
    case Keyword.fetch(opts, :tx_executor) do
      {:ok, executor} when is_function(executor, 3) ->
        executor

      {:ok, _other} ->
        raise ArgumentError, ":tx_executor must be a 3-arity function"

      :error ->
        raise ArgumentError, ":tx_executor is required"
    end
  end

  @spec to_block_ctx(Header.t()) :: BlockCtx.t()
  defp to_block_ctx(%Header{} = header) do
    %BlockCtx{
      number: header.number,
      timestamp: header.timestamp,
      coinbase: header.coinbase,
      gaslimit: header.gas_limit,
      prevrandao: header.prev_randao,
      basefee: header.base_fee_per_gas,
      parent_beacon_block_root: header.parent_beacon_block_root
    }
  end
end
