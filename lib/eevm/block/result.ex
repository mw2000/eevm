defmodule EEVM.Block.Result do
  @moduledoc """
  The outcome of executing a block — the post-state database plus every
  commitment derived from it. Returned by `EEVM.Block.Processor.process_block/4`.

  ### Fields

  - `post_state_db` — the `EEVM.Database` after system calls and every
    transaction have been applied in order.
  - `receipts` — the per-transaction receipts, already carrying their
    `cumulative_gas_used` figures.
  - `state_root` — post-execution world-state MPT root.
  - `receipts_root` — MPT root of `{rlp(index) => rlp(receipt)}`.
  - `transactions_root` — MPT root of `{rlp(index) => rlp(transaction)}`.
  - `logs_bloom` — bitwise OR of every receipt's logs bloom.
  - `gas_used` — total gas consumed across all transactions (matches the
    final receipt's `cumulative_gas_used`, `0` when the block is empty).
  """

  alias EEVM.Block.{Bloom, Receipt}
  alias EEVM.Database

  @type t :: %__MODULE__{
          post_state_db: Database.t(),
          receipts: [Receipt.t()],
          state_root: binary(),
          receipts_root: binary(),
          transactions_root: binary(),
          logs_bloom: Bloom.t(),
          gas_used: non_neg_integer()
        }

  defstruct [
    :post_state_db,
    :receipts,
    :state_root,
    :receipts_root,
    :transactions_root,
    :logs_bloom,
    :gas_used
  ]
end
