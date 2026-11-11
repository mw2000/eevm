defmodule EEVM.Block.Result do
  @moduledoc """
  The outcome of executing a block — the post-state database plus every
  commitment derived from it. Returned by `EEVM.Block.Processor.process_block/4`.

  ### Fields

  - `db` — the `EEVM.Database` after system calls, every transaction, the
    withdrawals, and the request system calls have been applied in order.
    `post_state_db` is a deprecated copy, kept for one minor version.
  - `receipts` — the per-transaction receipts, already carrying their
    `cumulative_gas_used` figures.
  - `state_root` — post-execution world-state MPT root.
  - `receipts_root` — MPT root of `{rlp(index) => rlp(receipt)}`.
  - `transactions_root` — MPT root of `{rlp(index) => rlp(transaction)}`.
  - `logs_bloom` — bitwise OR of every receipt's logs bloom.
  - `gas_used` — total gas consumed across all transactions (matches the
    final receipt's `cumulative_gas_used`, `0` when the block is empty).
  - `requests` — the block's EIP-7685 requests, each a type byte followed by
    its payload (see `EEVM.Block.Requests`); `nil` before Prague.
  - `changes` — the block's writes as an `EEVM.StateChanges`. `EEVM.Block`
    has already committed them to `db` when the backend implements
    `c:EEVM.Database.commit/2`; `EEVM.Block.Processor` leaves this `nil`.
  - `trace` — with the `:tracer` option, one `EEVM.Tracer` per transaction,
    in block order; otherwise `nil`.
  """

  alias EEVM.Block.{Bloom, Receipt}
  alias EEVM.Database
  alias EEVM.Tracer

  @type t :: %__MODULE__{
          db: Database.t(),
          receipts: [Receipt.t()],
          state_root: binary(),
          receipts_root: binary(),
          transactions_root: binary(),
          logs_bloom: Bloom.t(),
          gas_used: non_neg_integer(),
          requests: [binary()] | nil,
          changes: EEVM.StateChanges.t() | nil,
          trace: [Tracer.t()] | nil,
          post_state_db: Database.t()
        }

  # The deprecated copy would print the database twice.
  @derive {Inspect, except: [:post_state_db]}
  defstruct [
    :db,
    :receipts,
    :state_root,
    :receipts_root,
    :transactions_root,
    :logs_bloom,
    :gas_used,
    :requests,
    :changes,
    :trace,
    :post_state_db
  ]
end
