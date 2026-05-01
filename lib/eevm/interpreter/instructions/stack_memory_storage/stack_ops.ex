defmodule EEVM.Interpreter.Instructions.StackMemoryStorage.StackOps do
  @moduledoc """
  Stack manipulation opcode: POP (0x50).

  Removes the top element from the stack and discards it. Fails with
  `:stack_underflow` if the stack is empty.
  """

  alias EEVM.Interpreter.{MachineState, Stack}

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x50, state) do
    case Stack.pop(state.frame.stack) do
      {:ok, _value, new_stack} ->
        {:ok,
         state
         |> MachineState.update_frame(&%{&1 | stack: new_stack})
         |> MachineState.advance_pc()}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
