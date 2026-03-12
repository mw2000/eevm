defmodule EEVM.Opcodes.System do
  @moduledoc """
  Backwards-compatible dispatcher for system opcodes.
  """

  alias EEVM.MachineState
  alias EEVM.Opcodes.System.{Creation, Termination}

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(op, state) when op in [0x00, 0xF3, 0xFD, 0xFE], do: Termination.execute(op, state)
  def execute(op, state) when op in [0xF0, 0xF1, 0xF5], do: Creation.execute(op, state)
  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
