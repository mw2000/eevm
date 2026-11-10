defmodule EEVM.Interpreter.Instructions.StackMemoryStorage.StackOps do
  @moduledoc """
  Stack manipulation opcodes: POP (0x50), DUP1–DUP16 (0x80–0x8F), and
  SWAP1–SWAP16 (0x90–0x9F).
  """

  @doc """
  Applies a stack manipulation opcode to the stack (a list, top first) and
  returns the new stack.

  - POP discards the top element.
  - DUPn pushes a copy of the nth element (DUP1 copies the top).
  - SWAPn exchanges the top element with the one n below it.

  The interpreter has already checked that the stack holds the opcode's inputs.

      iex> alias EEVM.Interpreter.Instructions.StackMemoryStorage.StackOps
      iex> StackOps.stack_op(0x50, [1, 2])
      [2]
      iex> StackOps.stack_op(0x81, [1, 2, 3])
      [2, 1, 2, 3]
      iex> StackOps.stack_op(0x91, [1, 2, 3, 4])
      [3, 2, 1, 4]
  """
  @spec stack_op(non_neg_integer(), [non_neg_integer()]) :: [non_neg_integer()]
  def stack_op(0x50, [_top | rest]), do: rest

  for n <- 1..16 do
    def stack_op(unquote(0x7F + n), stack), do: [:lists.nth(unquote(n), stack) | stack]

    def stack_op(unquote(0x8F + n), [top | rest]) do
      {between, [target | below]} = :lists.split(unquote(n - 1), rest)
      [target | between ++ [top | below]]
    end
  end
end
