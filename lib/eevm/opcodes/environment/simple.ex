defmodule EEVM.Opcodes.Environment.Simple do
  @moduledoc false

  alias EEVM.{MachineState, Stack}
  alias EEVM.Context.Block
  alias EEVM.Opcodes.Helpers

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x30, state), do: Helpers.push_value(state, state.contract.address)
  def execute(0x32, state), do: Helpers.push_value(state, state.tx.origin)
  def execute(0x33, state), do: Helpers.push_value(state, state.contract.caller)
  def execute(0x34, state), do: Helpers.push_value(state, state.contract.callvalue)
  def execute(0x36, state), do: Helpers.push_value(state, byte_size(state.contract.calldata))
  def execute(0x38, state), do: Helpers.push_value(state, byte_size(state.code))
  def execute(0x3A, state), do: Helpers.push_value(state, state.tx.gasprice)
  def execute(0x3D, state), do: Helpers.push_value(state, byte_size(state.return_data))
  def execute(0x41, state), do: Helpers.push_value(state, state.block.coinbase)
  def execute(0x42, state), do: Helpers.push_value(state, state.block.timestamp)
  def execute(0x43, state), do: Helpers.push_value(state, state.block.number)
  def execute(0x44, state), do: Helpers.push_value(state, state.block.prevrandao)
  def execute(0x45, state), do: Helpers.push_value(state, state.block.gaslimit)
  def execute(0x46, state), do: Helpers.push_value(state, state.block.chain_id)
  def execute(0x48, state), do: Helpers.push_value(state, state.block.basefee)
  def execute(0x5A, state), do: Helpers.push_value(state, state.gas)

  def execute(0x40, state) do
    with {:ok, block_num, s1} <- Stack.pop(state.stack),
         hash = Block.hash(state.block, block_num),
         {:ok, s2} <- Stack.push(s1, hash) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
