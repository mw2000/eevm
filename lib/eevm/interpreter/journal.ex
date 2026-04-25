defmodule EEVM.Interpreter.Journal do
  @moduledoc """
  Snapshot/commit semantics for nested EVM call frames.

  ## EVM Concepts

  When a child frame runs (CALL, DELEGATECALL, STATICCALL, CREATE, CREATE2),
  its mutations to world state become permanent only if the child halts
  normally (`:stopped`). On revert, out-of-gas, invalid, or any other abnormal
  halt, those mutations must be discarded — the parent must observe the world
  state it had before the child was spawned.

  Concretely, six fields of `EEVM.Interpreter.MachineState` participate in
  this revert behaviour:

  - `db` — the unified world database (accounts + storage)
  - `logs` — emitted log entries (parent's logs come first, then child's)
  - `accessed_addresses` — EIP-2929 access list
  - `accessed_storage_keys` — EIP-2929 access list
  - `created_addresses` — EIP-6780 set of contracts created in this tx
  - `touched_addresses` — EIP-161 cleanup set

  The `tracer` field is *not* revertible — trace events accumulate
  monotonically and are always preserved across child boundaries regardless
  of the child's outcome.

  ## Why a dedicated module

  Before this module existed, every call/create site re-implemented the
  conditional "if child succeeded, take child's six fields, else keep
  parent's" with six per-field local variables and six explicit `Map.put/3`
  calls. Centralising the merge means: (1) a future revertible field is
  added in one place, not six; (2) call sites read as "merge child result"
  rather than as a hand-wired six-field reconciliation.

  ## What this module does NOT cover

  - Stack and memory: those are local to a frame and never propagate child
    → parent on success or failure.
  - Gas accounting: the parent's gas refund of `child.gas` happens at the
    call site, not here, because the math depends on opcode-specific
    bookkeeping (e.g. CREATE's deposit cost).
  - The `:db` override in CREATE: the success path replaces `child.db` with
    a post-deploy db that has the runtime code installed. Call sites apply
    that override after `merge_child_result/2`.
  """

  alias EEVM.Interpreter.MachineState

  @doc """
  Merge the result of a child frame back into its parent.

  - On success (`status: :stopped`): the child's mutations to revertible
    fields are promoted into the parent. Logs are *appended*, with the
    parent's existing logs preceding the child's in emission order.
  - On any other halt: the parent's revertible fields are kept untouched.

  In both cases the child's tracer state is propagated into the parent,
  because tracing accumulates regardless of execution outcome.
  """
  @spec merge_child_result(MachineState.t(), MachineState.t()) :: MachineState.t()
  def merge_child_result(%MachineState{} = parent, %MachineState{status: :stopped} = child) do
    %{
      parent
      | db: child.db,
        logs: parent.logs ++ child.logs,
        accessed_addresses: child.accessed_addresses,
        accessed_storage_keys: child.accessed_storage_keys,
        created_addresses: child.created_addresses,
        touched_addresses: child.touched_addresses,
        tracer: child.tracer
    }
  end

  def merge_child_result(%MachineState{} = parent, %MachineState{} = child) do
    %{parent | tracer: child.tracer}
  end
end
