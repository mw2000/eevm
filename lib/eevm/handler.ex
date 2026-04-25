defmodule EEVM.Handler do
  @moduledoc """
  End-to-end transaction handler.

  ## EVM Concepts

  A signed Ethereum transaction is not a single operation — it is a sequence
  of well-defined steps the client must perform against current world state.
  This module orchestrates those steps, deferring each phase to a sibling
  module so the layering stays inspectable:

  - `EEVM.Handler.Validation`    — decode → recover sender → validate
  - `EEVM.Handler.PreExecution`  — charge upfront → intrinsic gas → bump nonce
  - `EEVM.Handler.Execution`     — top-level CALL or CREATE through the EVM
  - `EEVM.Handler.PostExecution` — settle refund, credit coinbase, build result

  This split mirrors revm's `handler/` crate (`validation.rs`,
  `pre_execution.rs`, `execution.rs`, `post_execution.rs`) and keeps each
  phase independently testable.

  ## Elixir Learning Notes

  - The pipeline is a `with` chain: each step returns `{:ok, …}` or
    `{:error, reason}`, and the chain short-circuits on the first failure.
  - The sender is represented two ways: as a 20-byte binary (from the wire
    and from `Signer.recover_sender/2`) and as an integer (inside
    `EEVM.Context.Transaction` and `EEVM.Database`'s key space).
  """

  alias EEVM.{Config, Database, TransactionResult}
  alias EEVM.Context.Block
  alias EEVM.Handler.{Execution, PostExecution, PreExecution, Validation}
  alias EEVM.Transaction.{AccessList, Blob, FeeMarket, Legacy}

  @type wire_tx ::
          Legacy.t() | AccessList.t() | FeeMarket.t() | Blob.t() | binary()

  @type opts :: [
          hardfork: EEVM.HardforkConfig.spec_id(),
          chain_id: non_neg_integer(),
          config: Config.t()
        ]

  @default_chain_id 1

  @doc """
  Execute a single transaction end-to-end.

  `tx_or_bytes` may be either raw wire bytes (legacy RLP or a typed envelope
  prefix + RLP) or one of the typed `EEVM.Transaction.*` structs.

  ## Options

  - `:chain_id` — chain id used when recovering the sender (default: `1`).
  - `:hardfork` — hardfork spec id governing gas rules and EIP activation
    (default: `:cancun`).
  - `:config` — fully assembled `EEVM.Config` to use instead of deriving one
    from `:hardfork`. Takes precedence when both are provided.

  ## Returns

  - `{:ok, %EEVM.TransactionResult{}}` for any transaction that made it past
    validation — including reverted ones. Inspect `result.status` to tell
    success from revert.
  - `{:error, reason}` when decoding, sender recovery, validation, or upfront
    balance charging fail. The database is returned unchanged in that case.
  """
  @spec execute(wire_tx(), Block.t(), Database.t(), opts()) ::
          {:ok, TransactionResult.t()} | {:error, atom()}
  def execute(tx_or_bytes, %Block{} = block, %Database{} = db, opts \\ []) do
    chain_id = Keyword.get(opts, :chain_id, @default_chain_id)
    config = Validation.resolve_config(opts)

    with {:ok, wire_tx} <- Validation.ensure_decoded(tx_or_bytes),
         {:ok, sender_bytes} <- Validation.recover_sender(wire_tx, chain_id),
         {:ok, tx_ctx} <- Validation.build_tx_context(wire_tx, sender_bytes),
         :ok <- Validation.validate(tx_ctx, db, block, config.hardfork),
         {:ok, db_after_upfront} <- PreExecution.charge_upfront(db, tx_ctx, block),
         {:ok, db_nonce_bumped, execution_gas} <-
           PreExecution.prepare_execution(db_after_upfront, tx_ctx) do
      {final_state, contract_address} =
        Execution.run_top_level(tx_ctx, db_nonce_bumped, block, config, execution_gas)

      PostExecution.finalize(
        final_state,
        contract_address,
        tx_ctx,
        sender_bytes,
        db_nonce_bumped,
        block
      )
    end
  end
end
