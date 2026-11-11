defmodule EEVM.CallResult do
  @moduledoc """
  The outcome of a message call: `EEVM.run/2`, `EEVM.call/4`, or
  `EEVM.create/3`.

  | Field | Description |
  |-------|-------------|
  | `status` | `:success`, `:revert`, or `{:halt, reason}` (see `t:status/0`) |
  | `return_data` | Bytes from RETURN or REVERT (see `EEVM.revert_reason/1`); empty after a halt |
  | `gas_used` | Gas consumed, after the refund |
  | `gas_left` | Gas remaining from the `:gas` limit |
  | `logs` | Logs emitted, in order; empty unless `status` is `:success` |
  | `db` | The `EEVM.Database` after the call, writes still in its overlay; unchanged unless `status` is `:success` |
  | `changes` | `db`'s pending writes as an `EEVM.StateChanges`; message calls never commit them |
  | `contract_address` | The new contract's address after a successful `EEVM.create/3`, else `nil` |
  | `trace` | The `EEVM.Tracer` when run with `tracer:`, else `nil` |
  | `stack` | The final stack, top first, when run with `debug: true`, else `nil` |
  """

  alias EEVM.Block.Bloom
  alias EEVM.Database
  alias EEVM.Tracer

  @typedoc """
  How execution ended: `:success` after STOP or RETURN, `:revert` after
  REVERT, or `{:halt, reason}` after an exceptional halt, which consumes all
  gas. `reason` is an `t:EEVM.Error.halt_reason/0`, such as `:out_of_gas` or
  `:invalid_opcode`.
  """
  @type status :: :success | :revert | {:halt, EEVM.Error.halt_reason()}

  @type t :: %__MODULE__{
          status: status(),
          return_data: binary(),
          gas_used: non_neg_integer(),
          gas_left: non_neg_integer(),
          logs: [Bloom.log_entry()],
          db: Database.t(),
          changes: EEVM.StateChanges.t(),
          contract_address: non_neg_integer() | nil,
          trace: Tracer.t() | nil,
          stack: [non_neg_integer()] | nil
        }

  defstruct status: :success,
            return_data: <<>>,
            gas_used: 0,
            gas_left: 0,
            logs: [],
            db: nil,
            changes: %EEVM.StateChanges{},
            contract_address: nil,
            trace: nil,
            stack: nil
end
