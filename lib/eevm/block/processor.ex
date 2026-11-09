defmodule EEVM.Block.Processor do
  @moduledoc """
  Lower-level block engine with an injectable transaction executor: system
  calls, then transactions in order, then beacon-chain withdrawals, then the
  commitments a consensus-level verifier will check.

  Most callers want `EEVM.Block.execute/4`, which validates the block, runs
  each transaction through `EEVM.Handler`, and checks the commitments against
  the header. Use this module directly to plug in a custom executor.

  If any transaction fails (the injected executor returns an `{:error, _}`)
  the processor halts and reports the failing index. The post-state database
  is left at whatever the last *successful* transaction produced — this
  processor does not attempt optimistic rollback.

  ## Options

  Callers inject the executor and any per-block hooks:

  - `:tx_executor` — `(tx, %Context.Block{}, %Database{}) ->
    {:ok, tx_result} | {:error, reason}`. Each call receives the *current*
    database after all prior transactions and system calls have been
    applied. The returned `tx_result` is a map with keys `:status`,
    `:gas_used`, `:logs`, and `:db`, plus an optional `:tx_type` (default
    `:legacy`) that selects the EIP-2718 receipt encoding.
  - `:system_calls` — list of hooks, each `(%Database{}, %Context.Block{})
    -> %Database{}`. Executed in order, strictly before any transaction.
    The default is `[]`.
  - `:tx_encoder` — `(tx) -> binary` used to compute the
    `transactions_root`. Defaults to `EEVM.Transaction.Envelope.encode/1`,
    which handles every typed envelope this codebase knows about. Tests
    using plain maps supply their own.
  - `:withdrawals` — list of `EEVM.Block.Withdrawal` structs (EIP-4895).
    Applied as flat balance credits after the transaction fold and before
    the state root is computed, so the returned `state_root` already
    reflects them. Defaults to `[]`.
  - `:block_context` — the `EEVM.Context.Block` handed to system calls and
    the executor. Defaults to one derived from the header's fields.
  """

  alias EEVM.Block.{Bloom, Header, Receipt, Result, Withdrawal}
  alias EEVM.Context.Block, as: BlockCtx
  alias EEVM.Database
  alias EEVM.MPT.Trie
  alias EEVM.StateRoot
  alias EEVM.Transaction.Envelope

  @gwei 1_000_000_000

  @type tx_result :: %{
          required(:status) => 0 | 1,
          required(:gas_used) => non_neg_integer(),
          required(:logs) => [Bloom.log_entry()],
          required(:db) => Database.t(),
          optional(:tx_type) => Receipt.tx_type()
        }

  @type tx_executor :: (term(), BlockCtx.t(), Database.t() ->
                          {:ok, tx_result()} | {:error, term()})

  @type system_call :: (Database.t(), BlockCtx.t() -> Database.t())

  @type tx_encoder :: (term() -> binary())

  @type process_opts :: [
          tx_executor: tx_executor(),
          system_calls: [system_call()],
          tx_encoder: tx_encoder(),
          withdrawals: [Withdrawal.t()],
          block_context: BlockCtx.t()
        ]

  @type process_error :: {:tx_failed, non_neg_integer(), term()}

  @doc """
  Execute every phase of the block and produce a `%EEVM.Block.Result{}`.

  The caller owns `pre_state_db` and must pass an injected `:tx_executor`.
  See the module doc for the full option list.

  Returns:

  - `{:ok, %Result{}}` on success.
  - `{:error, {:tx_failed, index, :gas_allowance_exceeded}}` when a
    transaction's `gas_limit` exceeds the gas left in the block
    (`header.gas_limit` minus the gas used so far).
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
    withdrawals = Keyword.get(opts, :withdrawals, [])

    block_ctx = Keyword.get_lazy(opts, :block_context, fn -> to_block_ctx(header) end)
    db_after_system = apply_system_calls(pre_state_db, block_ctx, system_calls)

    case execute_transactions(transactions, block_ctx, db_after_system, tx_executor, header) do
      {:ok, receipts, post_tx_db, gas_used} ->
        post_db = apply_withdrawals(post_tx_db, withdrawals)
        {:ok, build_result(post_db, receipts, transactions, gas_used, tx_encoder)}

      {:error, _} = error ->
        error
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

  @spec execute_transactions([term()], BlockCtx.t(), Database.t(), tx_executor(), Header.t()) ::
          {:ok, [Receipt.t()], Database.t(), non_neg_integer()}
          | {:error, {:tx_failed, non_neg_integer(), term()}}
  defp execute_transactions(transactions, block_ctx, db, tx_executor, %Header{} = header) do
    initial = {[], db, 0, 0}

    transactions
    |> Enum.reduce_while(initial, fn tx, {receipts, db_acc, cumulative_gas, index} ->
      # A transaction may only claim the gas still left in the block.
      if tx_gas_limit(tx) > header.gas_limit - cumulative_gas do
        {:halt, {:error, {:tx_failed, index, :gas_allowance_exceeded}}}
      else
        case tx_executor.(tx, block_ctx, db_acc) do
          {:ok, %{status: status, gas_used: gas_used, logs: logs, db: new_db} = tx_result} ->
            new_cumulative = cumulative_gas + gas_used

            receipt = %Receipt{
              tx_type: Map.get(tx_result, :tx_type, :legacy),
              status: status,
              cumulative_gas_used: new_cumulative,
              logs: logs,
              logs_bloom: Bloom.from_logs(logs)
            }

            {:cont, {[receipt | receipts], new_db, new_cumulative, index + 1}}

          {:error, reason} ->
            {:halt, {:error, {:tx_failed, index, reason}}}
        end
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
  # Phase 4 — withdrawals (EIP-4895)
  # ---------------------------------------------------------------------------

  # Each withdrawal is a flat balance credit; `amount` is in gwei per the EIP,
  # so we scale to wei before applying.
  @spec apply_withdrawals(Database.t(), [Withdrawal.t()]) :: Database.t()
  defp apply_withdrawals(db, withdrawals) do
    Enum.reduce(withdrawals, db, fn %Withdrawal{address: addr, amount: amount}, db_acc ->
      credit_balance(db_acc, addr, amount * @gwei)
    end)
  end

  defp credit_balance(db, _addr, 0), do: db

  defp credit_balance(db, addr, amount),
    do: Database.set_balance(db, addr, Database.get_balance(db, addr) + amount)

  # ---------------------------------------------------------------------------
  # Phase 5 — commitments
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
    |> Enum.map(fn {receipt, index} -> {ExRLP.encode(index), Receipt.encode(receipt)} end)
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
      basefee: header.base_fee_per_gas || 0,
      parent_beacon_block_root: header.parent_beacon_block_root || 0
    }
  end
end
