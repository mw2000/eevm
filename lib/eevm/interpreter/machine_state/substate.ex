defmodule EEVM.Interpreter.MachineState.Substate do
  @moduledoc """
  Transaction-scoped accumulators that survive nested call frames.

  ### Fields

  - `touched_addresses` — EIP-161 cleanup set; empty accounts touched during
    the transaction are deleted on commit.
  - `accessed_addresses` / `accessed_storage_keys` — EIP-2929 access lists
    powering cold/warm gas pricing.
  - `created_addresses` — EIP-6780 set of contracts created in this tx;
    only these can be fully deleted by `SELFDESTRUCT` post-Cancun. An
    address joins the set before its initcode runs, so a `SELFDESTRUCT`
    during init deletes it, and leaves the set if that creation fails.
  - `selfdestructed_addresses` — accounts whose `SELFDESTRUCT` deletes them
    (all of them pre-Cancun, only those in `created_addresses` under
    EIP-6780). They stay in the database until the transaction ends, then
    `EEVM.Interpreter.finalize/3` deletes them with their storage.
  - `original_storage` — per-tx snapshot of the first-observed value of
    each storage slot, keyed by `{address, key}`, used by EIP-2200 `SSTORE`
    accounting.
  - `transient_storage` — EIP-1153 per-tx store keyed by `{address, slot}`,
    passed into every child frame and cleared at tx end.
  - `logs` — emitted log entries, newest first so LOG and frame merges
    prepend; `EEVM.logs/1` and the transaction result reverse them into
    emission order.
  - `program_cache` — what is known of every code blob run so far, keyed by
    the code: its decoded program once a frame has decoded it
    (`EEVM.Interpreter.InstructionTable.decode/3`), else its JUMPDEST map
    once a frame has jumped in it (`EEVM.Interpreter.InstructionTable.jumpdests/1`).
    A contract called many times is analysed once.

  The first eight fields revert together when a child frame fails (see
  `EEVM.Interpreter.Journal`); `program_cache` is a cache and survives.
  Stack, memory, pc, and gas are *not* substate — they belong to the
  per-frame execution context.
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
          selfdestructed_addresses: MapSet.t(non_neg_integer()),
          original_storage: %{{non_neg_integer(), non_neg_integer()} => non_neg_integer()},
          transient_storage: %{{non_neg_integer(), non_neg_integer()} => non_neg_integer()},
          logs: [log_entry()],
          program_cache: %{binary() => EEVM.Interpreter.InstructionTable.program() | binary()}
        }

  defstruct touched_addresses: nil,
            accessed_addresses: nil,
            accessed_storage_keys: nil,
            created_addresses: nil,
            selfdestructed_addresses: nil,
            original_storage: %{},
            transient_storage: %{},
            logs: [],
            program_cache: %{}

  @doc """
  Builds a substate, taking each field from the option of the same name and
  defaulting to an empty set, map, or list.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      touched_addresses: Keyword.get(opts, :touched_addresses, MapSet.new()),
      accessed_addresses: Keyword.get(opts, :accessed_addresses, MapSet.new()),
      accessed_storage_keys: Keyword.get(opts, :accessed_storage_keys, MapSet.new()),
      created_addresses: Keyword.get(opts, :created_addresses, MapSet.new()),
      selfdestructed_addresses: Keyword.get(opts, :selfdestructed_addresses, MapSet.new()),
      original_storage: Keyword.get(opts, :original_storage, %{}),
      transient_storage: Keyword.get(opts, :transient_storage, %{}),
      logs: Keyword.get(opts, :logs, []),
      program_cache: Keyword.get(opts, :program_cache, %{})
    }
  end
end
