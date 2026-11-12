defmodule EEVM.Handler do
  @moduledoc """
  End-to-end transaction handler.

  Orchestrates the per-transaction pipeline, deferring each phase to a
  sibling module so the layering stays inspectable:

  - `EEVM.Handler.Validation`    — decode → recover sender → validate
  - `EEVM.Handler.PreExecution`  — charge upfront → intrinsic gas → bump nonce →
    apply EIP-7702 authorizations
  - `EEVM.Handler.Execution`     — top-level CALL or CREATE through the EVM
  - `EEVM.Handler.PostExecution` — settle refund, credit coinbase, build result

  This split mirrors revm's `handler/` crate (`validation.rs`,
  `pre_execution.rs`, `execution.rs`, `post_execution.rs`) and keeps each
  phase independently testable.
  """

  alias EEVM.{BlockEnv, Config, Database, TransactionError, TransactionResult, TxEnv}
  alias EEVM.Handler.{Execution, PostExecution, PreExecution, Validation}
  alias EEVM.Transaction.Validator

  @typedoc """
  A transaction: raw signed bytes, a signed `EEVM.Transaction` struct, or,
  for simulation, an unsigned `EEVM.TxEnv` whose `origin` is the sender.
  """
  @type wire_tx :: Validation.wire_tx() | TxEnv.t()

  @type opts :: [
          hardfork: EEVM.HardforkConfig.spec_id(),
          config: Config.t(),
          tracer: boolean() | EEVM.Tracer.t(),
          commit: boolean(),
          details: boolean(),
          chain_id: non_neg_integer()
        ]

  @doc """
  Execute a single transaction end-to-end. `EEVM.transact/4` delegates here;
  call that instead.

  `tx_or_bytes` may be either raw wire bytes (legacy RLP or a typed envelope
  prefix + RLP) or one of the typed `EEVM.Transaction.*` structs. For
  simulation it may also be an unsigned `EEVM.TxEnv`: its `origin` is the
  sender, with no signature to recover, and every other rule applies unless
  a simulation switch in the config turns it off.

  ## Options

  - `:config` — the `EEVM.Config`: hardfork, chain id (used to recover the
    sender and check EIP-7702 authorizations), custom precompiles, and the
    simulation switches, which are never for consensus.
  - `:hardfork` — shorthand for `config: EEVM.Config.new(hardfork)` (default
    `:cancun`). `:config` takes precedence when both are given.
  - `:tracer` — `true` or an `EEVM.Tracer` to record an EIP-3155 trace,
    returned as `result.trace`.
  - `:commit` — `false` to leave the writes in `result.db`'s overlay and
    skip `result.changes`; `EEVM.Block` does this to commit once per block.
    By default the writes are committed when the backend implements
    `c:EEVM.Database.commit/2`.
  - `:details` — `true` to return each rejection as
    `{:error, %EEVM.TransactionError{}}`, which carries the values the rule
    compared (the nonces, balance and cost, fees, gas limits) next to the
    reason. Default `false`: `{:error, reason}` with the bare atom.
  - `:chain_id` — deprecated; set it with `EEVM.Config.new/2`. Overrides the
    config's chain id when given.

  ## Returns

  - `{:ok, %EEVM.TransactionResult{}}` for any transaction that made it past
    validation, including reverted and halted ones. Inspect `result.status`
    to tell them apart.
  - `{:error, reason}` when decoding, sender recovery, validation, or upfront
    balance charging fail, and `{:error, {:database, reason}}` when the
    backend fails a read or commit. The database is unchanged in each case.
  """
  @spec execute(wire_tx(), BlockEnv.t(), Database.t(), opts()) ::
          {:ok, TransactionResult.t()} | {:error, EEVM.Error.reason() | TransactionError.t()}
  def execute(tx_or_bytes, %BlockEnv{} = block, %Database{} = db, opts \\ []) do
    Database.catch_read_errors(fn ->
      with {:ok, result} <- run(tx_or_bytes, block, db, opts) do
        finish(result, Keyword.get(opts, :commit, true))
      else
        {:error, reason, details} -> rejected(reason, details, opts)
        {:error, reason} -> rejected(reason, %{}, opts)
      end
    end)
  end

  defp rejected(reason, details, opts) do
    if Keyword.get(opts, :details, false),
      do: {:error, %TransactionError{reason: reason, details: details}},
      else: {:error, reason}
  end

  defp run(tx_or_bytes, block, db, opts) do
    config = Validation.resolve_config(opts)
    chain_id = config.chain_id

    with {:ok, tx_ctx} <- tx_env(tx_or_bytes, chain_id),
         :ok <- Validator.check(tx_ctx, db, block, config),
         # GASPRICE (0x3A) reads the price per gas the sender pays (EIP-1559).
         tx_ctx = %{tx_ctx | gas_price: PreExecution.effective_gas_price(tx_ctx, block)},
         {:ok, db_after_upfront} <- PreExecution.charge_upfront(db, tx_ctx, block, config),
         {:ok, db_nonce_bumped, execution_gas} <-
           PreExecution.prepare_execution(db_after_upfront, tx_ctx, config.hardfork) do
      {db_authorized, authorization} =
        PreExecution.apply_authorizations(db_nonce_bumped, tx_ctx, chain_id)

      {final_state, contract_address} =
        Execution.run_top_level(
          tx_ctx,
          db_authorized,
          block,
          config,
          execution_gas,
          authorization,
          Validation.resolve_tracer(opts)
        )

      PostExecution.finalize(
        final_state,
        contract_address,
        tx_ctx,
        tx_ctx.origin,
        db_authorized,
        block
      )
    end
  end

  # An unsigned TxEnv is impersonation: its origin is the sender as given.
  defp tx_env(%TxEnv{} = tx, _chain_id) do
    cond do
      not is_binary(tx.data) or EEVM.hex_string?(tx.data) ->
        raise ArgumentError,
              "TxEnv :data must be bytes (decode hex with EEVM.bytes/1), got: " <>
                inspect(tx.data, printable_limit: 40)

      not address?(tx.origin) or not (tx.to == nil or address?(tx.to)) ->
        raise ArgumentError,
              "TxEnv :origin and :to must be integer addresses, :to may be nil " <>
                "(convert a hex address with EEVM.address/1), got: " <>
                "origin #{inspect(tx.origin)}, to #{inspect(tx.to)}"

      true ->
        {:ok, tx}
    end
  end

  defp tx_env(tx_or_bytes, chain_id) do
    with {:ok, wire_tx} <- Validation.ensure_decoded(tx_or_bytes),
         {:ok, sender} <- Validation.recover_sender(wire_tx, chain_id) do
      Validation.build_tx_context(wire_tx, sender)
    end
  end

  defp address?(address), do: is_integer(address) and address >= 0 and address < 2 ** 160

  defp finish(%TransactionResult{} = result, false), do: {:ok, result}

  defp finish(%TransactionResult{db: db} = result, true) do
    with {:ok, committed} <- Database.commit_if_supported(db) do
      {:ok, %{result | db: committed, post_state_db: committed, changes: Database.changes(db)}}
    end
  end
end
