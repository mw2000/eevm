defmodule EEVM.Interpreter.Instructions.StackMemoryStorage.StackOps do
  @moduledoc """
  Stack manipulation opcode: POP (0x50), which discards the top element.
  """

  @doc """
  Applies POP to the stack (a list, top first). The interpreter has already
  checked that the stack is not empty.

      iex> EEVM.Interpreter.Instructions.StackMemoryStorage.StackOps.stack_op(0x50, [1, 2])
      [2]
  """
  @spec stack_op(non_neg_integer(), [non_neg_integer()]) :: [non_neg_integer()]
  def stack_op(0x50, [_top | rest]), do: rest
end
