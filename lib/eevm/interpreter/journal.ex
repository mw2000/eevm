defmodule EEVM.Interpreter.Journal do
  @moduledoc """
  Snapshot/commit semantics for nested EVM call frames.

  When a child frame halts normally (`:stopped`), its mutations to the
  parent's revertible fields are promoted; on any other halt they are
  discarded and the parent observes the pre-call state.

  Revertible fields (the `db` plus all of `substate`) participate in the
  merge:

  - `db` — the unified world database (accounts + storage)
  - `substate.logs` — emitted log entries (parent's first, then child's)
  - `substate.accessed_addresses` — EIP-2929 access list
  - `substate.accessed_storage_keys` — EIP-2929 access list
  - `substate.created_addresses` — EIP-6780 set of contracts created in this tx
  - `substate.touched_addresses` — EIP-161 cleanup set

  The `tracer` field is *not* revertible — trace events accumulate
  monotonically and are always preserved across child boundaries regardless
  of the child's outcome.

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
    merged_substate = %{child.substate | logs: parent.substate.logs ++ child.substate.logs}
    %{parent | db: child.db, substate: merged_substate, tracer: child.tracer}
  end

  def merge_child_result(%MachineState{} = parent, %MachineState{} = child) do
    %{parent | tracer: child.tracer}
  end
end
