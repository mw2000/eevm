defmodule EEVM.Interpreter.Journal do
  @moduledoc """
  Commit/discard semantics for nested call frames.

  Six `EEVM.Interpreter.MachineState` fields are revertible: `db`, `logs`,
  `accessed_addresses`, `accessed_storage_keys`, `created_addresses`, and
  `touched_addresses`. On `:stopped` the child's values are promoted into
  the parent (logs appended, parent first). On any other halt only the child's
  `tracer` is propagated — tracing accumulates regardless of outcome.

  Out of scope: stack/memory (frame-local), gas accounting (callsite-specific
  for CREATE deposits), and CREATE's runtime-code DB override (applied by the
  callsite after `merge_child_result/2`).
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
