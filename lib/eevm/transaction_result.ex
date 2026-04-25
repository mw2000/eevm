defmodule EEVM.TransactionResult do
  @moduledoc """
  Result of running a single transaction through the end-to-end execution pipeline.

  ## EVM Concepts

  Every Ethereum transaction that passes validation produces three things:

  - A **receipt** — status flag, cumulative gas used, logs, and logs bloom —
    which is what nodes hash into the block's receipts trie. See Yellow Paper
    §4.3.1.
  - A **post-state database** — the world state after the transaction's side
    effects (balance moves, storage writes, nonce bumps, code deployment).
  - **Return data / contract address** — the raw output of the top-level call,
    or the newly deployed address for a CREATE transaction (`to == nil`).

  This struct bundles those outputs for consumers (test harnesses, block
  executors, RPC layers). Transactions that fail validation *before* execution
  never produce a `TransactionResult` — the pipeline returns `{:error, reason}`
  in that case and the caller is expected not to apply any state changes.

  ### `status` values

  - `:success` — top-level execution terminated with STOP or RETURN. Receipt
    status byte is `1`.
  - `:reverted` — execution halted via REVERT. Receipt status byte is `0` and
    state changes are rolled back, but the sender is still charged for gas.
  - `:failed_validation` — used internally by helpers that need to describe
    a pre-execution failure in the same shape; the pipeline itself returns
    `{:error, reason}` for these cases rather than a struct.

  ## Elixir Learning Notes

  - Using an atom tag (`:success | :reverted | :failed_validation`) for the
    result status lets consumers pattern match on success vs. failure without
    poking at numeric receipt flags.
  - The `receipt` field is a plain map (not a nested struct) because the
    Ethereum receipt shape is small and stable — a map keeps construction
    cheap and keeps serializers flexible.
  """

  alias EEVM.{Bloom, Database}

  @type status :: :success | :reverted | :failed_validation

  @type log_entry :: %{
          address: non_neg_integer(),
          data: binary(),
          topics: [non_neg_integer()]
        }

  @type receipt :: %{
          status: 0 | 1,
          cumulative_gas_used: non_neg_integer(),
          logs_bloom: Bloom.t(),
          logs: [log_entry()]
        }

  @type t :: %__MODULE__{
          status: status(),
          gas_used: non_neg_integer(),
          gas_refunded: non_neg_integer(),
          sender: non_neg_integer(),
          logs: [log_entry()],
          logs_bloom: Bloom.t(),
          receipt: receipt(),
          post_state_db: Database.t(),
          return_data: binary(),
          contract_address: non_neg_integer() | nil
        }

  defstruct [
    :status,
    :gas_used,
    :gas_refunded,
    :sender,
    :logs,
    :logs_bloom,
    :receipt,
    :post_state_db,
    :return_data,
    :contract_address
  ]
end
