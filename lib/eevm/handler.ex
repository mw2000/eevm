defmodule EEVM.Handler do
  @moduledoc """
  Top-level transaction handler.

  Orchestrates a single transaction across four phases, each in its own module:

  - `EEVM.Handler.Validation`    — decode, recover sender, validate
  - `EEVM.Handler.PreExecution`  — charge upfront fee, deduct intrinsic gas, bump nonce
  - `EEVM.Handler.Execution`     — top-level CALL or CREATE through the EVM
  - `EEVM.Handler.PostExecution` — apply refund, pay coinbase, build result

  The phase split mirrors revm's `handler/` crate.

  Sender addresses cross a representation boundary inside the pipeline: the
  wire and `Signer.recover_sender/2` produce 20-byte binaries, while
  `EEVM.Context.Transaction` and `EEVM.Database` key on integer addresses.
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
