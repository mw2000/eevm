defmodule EEVM.Opcodes.Environment do
  @moduledoc """
  Backwards-compatible dispatcher for environment opcodes.
  """

  alias EEVM.MachineState

  alias EEVM.Opcodes.Environment.{
    Data,
    External,
    Simple
  }

  @simple_ops [
    0x30,
    0x32,
    0x33,
    0x34,
    0x36,
    0x38,
    0x3A,
    0x3D,
    0x40,
    0x41,
    0x42,
    0x43,
    0x44,
    0x45,
    0x46,
    0x48,
    0x5A
  ]
  @data_ops [0x35, 0x37, 0x39, 0x3E]
  @external_ops [0x31, 0x3B, 0x3C, 0x3F, 0x47]

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(op, state) when op in @simple_ops, do: Simple.execute(op, state)
  def execute(op, state) when op in @data_ops, do: Data.execute(op, state)
  def execute(op, state) when op in @external_ops, do: External.execute(op, state)
  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
