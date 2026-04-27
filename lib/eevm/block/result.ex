defmodule EEVM.Block.Result do
  @moduledoc """
  Output of `EEVM.Block.Processor.process_block/4`: post-state database plus
  the four header commitments (`state_root`, `receipts_root`,
  `transactions_root`, `logs_bloom`), the `receipts` list, and total
  `gas_used`. Built once and returned unchanged.
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
