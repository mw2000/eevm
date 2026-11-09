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

  alias EEVM.{BlockEnv, Config, Database, TransactionResult}
  alias EEVM.Handler.{Execution, PostExecution, PreExecution, Validation}

  @type wire_tx :: Validation.wire_tx()

  @type opts :: [
          hardfork: EEVM.HardforkConfig.spec_id(),
          config: Config.t(),
          tracer: boolean() | EEVM.Tracer.t(),
          chain_id: non_neg_integer()
        ]

  @doc """
  Execute a single transaction end-to-end. `EEVM.transact/4` delegates here;
  call that instead.

  `tx_or_bytes` may be either raw wire bytes (legacy RLP or a typed envelope
  prefix + RLP) or one of the typed `EEVM.Transaction.*` structs.

  ## Options

  - `:config` — the `EEVM.Config`: hardfork, chain id (used to recover the
    sender and check EIP-7702 authorizations), and custom precompiles.
  - `:hardfork` — shorthand for `config: EEVM.Config.new(hardfork)` (default
    `:cancun`). `:config` takes precedence when both are given.
  - `:tracer` — `true` or an `EEVM.Tracer` to record an EIP-3155 trace,
    returned as `result.trace`.
  - `:chain_id` — deprecated; set it with `EEVM.Config.new/2`. Overrides the
    config's chain id when given.

  ## Returns

  - `{:ok, %EEVM.TransactionResult{}}` for any transaction that made it past
    validation, including reverted and halted ones. Inspect `result.status`
    to tell them apart.
  - `{:error, reason}` when decoding, sender recovery, validation, or upfront
    balance charging fail. The database is returned unchanged in that case.
  """
  @spec execute(wire_tx(), BlockEnv.t(), Database.t(), opts()) ::
          {:ok, TransactionResult.t()} | {:error, EEVM.Error.reason()}
  def execute(tx_or_bytes, %BlockEnv{} = block, %Database{} = db, opts \\ []) do
    config = Validation.resolve_config(opts)
    chain_id = config.chain_id

    with {:ok, wire_tx} <- Validation.ensure_decoded(tx_or_bytes),
         {:ok, sender_bytes} <- Validation.recover_sender(wire_tx, chain_id),
         {:ok, tx_ctx} <- Validation.build_tx_context(wire_tx, sender_bytes),
         :ok <- Validation.validate(tx_ctx, db, block, config.hardfork),
         # GASPRICE (0x3A) reads the price per gas the sender pays (EIP-1559).
         tx_ctx = %{tx_ctx | gas_price: PreExecution.effective_gas_price(tx_ctx, block)},
         {:ok, db_after_upfront} <- PreExecution.charge_upfront(db, tx_ctx, block),
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
        sender_bytes,
        db_authorized,
        block
      )
    end
  end
end
