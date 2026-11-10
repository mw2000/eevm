defmodule EEVM.Interpreter.Instructions.Comparison do
  @moduledoc "EVM comparison opcodes: LT, GT, SLT, SGT, EQ, ISZERO."
  alias EEVM.Interpreter.Instructions.Helpers

  @doc """
  Applies a comparison opcode to the stack (a list, top first) and returns the new stack.

  | Byte | Mnemonic | Operation                                    |
  |------|----------|----------------------------------------------|
  | 0x10 | LT       | 1 if a < b (unsigned), else 0                |
  | 0x11 | GT       | 1 if a > b (unsigned), else 0                |
  | 0x12 | SLT      | 1 if a < b (signed two's complement), else 0 |
  | 0x13 | SGT      | 1 if a > b (signed two's complement), else 0 |
  | 0x14 | EQ       | 1 if a == b, else 0                          |
  | 0x15 | ISZERO   | 1 if a == 0, else 0 (unary)                  |

  The interpreter has already checked that the stack holds the opcode's inputs.

      iex> EEVM.Interpreter.Instructions.Comparison.stack_op(0x10, [1, 2, 9])
      [1, 9]
  """
  @spec stack_op(non_neg_integer(), [non_neg_integer()]) :: [non_neg_integer()]
  def stack_op(0x10, [a, b | rest]), do: [bit(a < b) | rest]
  def stack_op(0x11, [a, b | rest]), do: [bit(a > b) | rest]
  def stack_op(0x12, [a, b | rest]), do: [bit(Helpers.to_signed(a) < Helpers.to_signed(b)) | rest]
  def stack_op(0x13, [a, b | rest]), do: [bit(Helpers.to_signed(a) > Helpers.to_signed(b)) | rest]
  def stack_op(0x14, [a, b | rest]), do: [bit(a == b) | rest]
  def stack_op(0x15, [a | rest]), do: [bit(a == 0) | rest]

  defp bit(true), do: 1
  defp bit(false), do: 0
end
