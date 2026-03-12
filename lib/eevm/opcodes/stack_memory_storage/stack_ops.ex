defmodule EEVM.Opcodes.StackMemoryStorage.StackOps do
  @moduledoc false

  alias EEVM.{MachineState, Stack}

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x50, state) do
    case Stack.pop(state.stack) do
      {:ok, _value, new_stack} ->
        {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
