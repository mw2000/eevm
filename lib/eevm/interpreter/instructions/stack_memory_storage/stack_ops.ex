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

  # One clause per depth, so each DUPn and SWAPn is a single list pattern
  # rather than a walk with `:lists.nth/2` or `:lists.split/2` (about a fifth
  # of a Solidity loop's time before, #193). For DUP3 and SWAP2:
  #
  #     def stack_op(0x82, [_, _, copied | _] = stack), do: [copied | stack]
  #     def stack_op(0x91, [top, x1, target | rest]), do: [target, x1, top | rest]
  for n <- 1..16 do
    skipped = List.duplicate(quote(do: _), n - 1)

    def stack_op(unquote(0x7F + n), [unquote_splicing(skipped), copied | _] = stack),
      do: [copied | stack]

    [top | between_and_target] = Macro.generate_unique_arguments(n + 1, __MODULE__)
    {between, [target]} = Enum.split(between_and_target, n - 1)

    def stack_op(unquote(0x8F + n), [
          unquote(top),
          unquote_splicing(between),
          unquote(target) | rest
        ]),
        do: [unquote(target), unquote_splicing(between), unquote(top) | rest]
  end
end
