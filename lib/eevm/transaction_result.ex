defmodule EEVM.TransactionResult do
  @moduledoc """
  Result of running a single transaction through the end-to-end execution
  pipeline.

  Bundles the outputs a caller needs after `EEVM.Handler.execute/4` returns:
  the receipt (status, cumulative gas, logs, logs bloom), the post-state
  database, and the top-level return data / newly created contract address.
  Transactions that fail pre-execution validation never produce a
  `TransactionResult` — the pipeline returns `{:error, reason}` in that case.

  ### `status` values

  - `:success` — top-level execution terminated with STOP or RETURN. Receipt
    status byte is `1`.
  - `:reverted` — execution halted via REVERT. Receipt status byte is `0` and
    state changes are rolled back, but the sender is still charged for gas.
  - `:failed_validation` — used internally by helpers that need to describe
    a pre-execution failure in the same shape; the pipeline itself returns
    `{:error, reason}` for these cases rather than a struct.
  """

  alias EEVM.Block.Bloom
  alias EEVM.Database

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
