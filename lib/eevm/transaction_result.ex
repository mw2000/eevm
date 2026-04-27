defmodule EEVM.TransactionResult do
  @moduledoc """
  Output of a single transaction through `EEVM.Handler`: status atom, gas
  accounting, logs and bloom, the receipt map (Yellow Paper §4.3.1 shape),
  the post-state database, top-level return data, and `contract_address`
  for CREATE transactions.

  `status` is `:success` (STOP/RETURN, receipt byte 1), `:reverted`
  (REVERT — sender pays gas, state rolled back, byte 0), or
  `:failed_validation`. Pre-execution validation failures return
  `{:error, reason}` directly, never this struct.
  """

  alias EEVM.Database
  alias EEVM.Block.Bloom

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
