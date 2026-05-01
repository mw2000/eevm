defmodule EEVM.Interpreter.MachineState.Substate do
  @moduledoc """
  Transaction-scoped accumulators that survive nested call frames.

  ## EVM Concepts

  The Yellow Paper calls this "substate" — fields that accumulate across
  successful call frames within a single transaction and are discarded
  on revert. Concretely:

  - `touched_addresses` — EIP-161 cleanup set; empty accounts touched during
    the transaction are deleted on commit.
  - `accessed_addresses` / `accessed_storage_keys` — EIP-2929 access lists
    powering cold/warm gas pricing.
  - `created_addresses` — EIP-6780 set of contracts created in this tx;
    only these can be fully deleted by `SELFDESTRUCT` post-Cancun.
  - `original_storage` — per-tx snapshot of the first-observed value of
    each storage slot, used by EIP-2200 `SSTORE` accounting.
  - `transient_storage` — EIP-1153 per-tx key/value store cleared at tx end.
  - `logs` — emitted log entries, parent-then-child on success.

  All seven fields revert together when a child frame fails (see
  `EEVM.Interpreter.Journal`). Stack, memory, pc, and gas are *not*
  substate — they belong to the per-frame execution context.
  """

  @type log_entry :: %{
          address: non_neg_integer(),
          data: binary(),
          topics: [non_neg_integer()]
        }

  @type t :: %__MODULE__{
          touched_addresses: MapSet.t(non_neg_integer()),
          accessed_addresses: MapSet.t(non_neg_integer()),
          accessed_storage_keys: MapSet.t({non_neg_integer(), non_neg_integer()}),
          created_addresses: MapSet.t(non_neg_integer()),
          original_storage: %{non_neg_integer() => non_neg_integer()},
          transient_storage: %{non_neg_integer() => non_neg_integer()},
          logs: [log_entry()]
        }

  defstruct touched_addresses: nil,
            accessed_addresses: nil,
            accessed_storage_keys: nil,
            created_addresses: nil,
            original_storage: %{},
            transient_storage: %{},
            logs: []

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      touched_addresses: Keyword.get(opts, :touched_addresses, MapSet.new()),
      accessed_addresses: Keyword.get(opts, :accessed_addresses, MapSet.new()),
      accessed_storage_keys: Keyword.get(opts, :accessed_storage_keys, MapSet.new()),
      created_addresses: Keyword.get(opts, :created_addresses, MapSet.new()),
      original_storage: Keyword.get(opts, :original_storage, %{}),
      transient_storage: Keyword.get(opts, :transient_storage, %{}),
      logs: Keyword.get(opts, :logs, [])
    }
  end
end
