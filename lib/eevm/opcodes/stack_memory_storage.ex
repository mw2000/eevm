defmodule EEVM.Opcodes.StackMemoryStorage do
  @moduledoc """
  Backwards-compatible dispatcher for stack/memory/storage opcodes.
  """

  alias EEVM.MachineState

  alias EEVM.Opcodes.StackMemoryStorage.{
    MemoryOps,
    StackOps,
    StorageOps
  }

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x50, state), do: StackOps.execute(0x50, state)

  def execute(op, state) when op in [0x51, 0x52, 0x53, 0x59, 0x5E],
    do: MemoryOps.execute(op, state)

  def execute(op, state) when op in [0x54, 0x55], do: StorageOps.execute(op, state)
  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
