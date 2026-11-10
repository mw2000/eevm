defmodule EEVM.TransactionResult do
  @moduledoc """
  The outcome of a transaction that passed validation, returned by
  `EEVM.transact/4`. A transaction that fails validation returns
  `{:error, reason}` instead, and the database is unchanged.

  | Field | Description |
  |-------|-------------|
  | `status` | `:success`, `:revert`, or `{:halt, reason}` (see `t:EEVM.CallResult.status/0`) |
  | `gas_used` | Gas the sender pays for, after the refund |
  | `gas_refunded` | Gas left unused by execution |
  | `sender` | The recovered sender address |
  | `contract_address` | The deployed contract's address, for a successful creation |
  | `return_data` | The top-level RETURN data on success, else empty |
  | `logs` | Logs emitted, in order; empty unless `status` is `:success` |
  | `receipt` | The `EEVM.Block.Receipt`, with `cumulative_gas_used` equal to `gas_used` |
  | `db` | The `EEVM.Database` after the transaction, fees and refunds included; committed when the backend implements `c:EEVM.Database.commit/2` |
  | `changes` | The `EEVM.StateChanges` the transaction wrote |
  | `trace` | The `EEVM.Tracer` when run with `tracer:`, else `nil` |

  `post_state_db` and `logs_bloom` are deprecated copies of `db` and
  `receipt.logs_bloom`, kept for one minor version.
  """

  alias EEVM.Block.{Bloom, Receipt}
  alias EEVM.CallResult
  alias EEVM.Database
  alias EEVM.Tracer

  @type status :: CallResult.status()

  @type log_entry :: Bloom.log_entry()

  @type t :: %__MODULE__{
          status: status(),
          gas_used: non_neg_integer(),
          gas_refunded: non_neg_integer(),
          sender: non_neg_integer(),
          contract_address: non_neg_integer() | nil,
          return_data: binary(),
          logs: [log_entry()],
          receipt: Receipt.t(),
          db: Database.t(),
          changes: EEVM.StateChanges.t() | nil,
          trace: Tracer.t() | nil,
          post_state_db: Database.t(),
          logs_bloom: Bloom.t()
        }

  defstruct [
    :status,
    :gas_used,
    :gas_refunded,
    :sender,
    :contract_address,
    :return_data,
    :logs,
    :receipt,
    :db,
    :changes,
    :trace,
    :post_state_db,
    :logs_bloom
  ]
end
