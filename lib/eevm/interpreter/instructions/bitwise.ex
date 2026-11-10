defmodule EEVM.Interpreter.Instructions.Bitwise do
  @moduledoc "EVM bitwise opcodes: AND, OR, XOR, NOT, BYTE, SHL, SHR, SAR, CLZ."
  import Bitwise

  alias EEVM.Interpreter.Instructions.Helpers

  @max_uint256 (1 <<< 256) - 1

  @doc """
  Applies a bitwise opcode to the stack (a list, top first) and returns the new stack.

  | Byte | Mnemonic | Operation                                         |
  |------|----------|---------------------------------------------------|
  | 0x16 | AND      | bitwise AND of a and b                            |
  | 0x17 | OR       | bitwise OR of a and b                             |
  | 0x18 | XOR      | bitwise XOR of a and b                            |
  | 0x19 | NOT      | bitwise complement (all 256 bits flipped)         |
  | 0x1A | BYTE     | byte at index i of x (big-endian, 0 = MSB)        |
  | 0x1B | SHL      | logical left shift: x << shift mod 2^256          |
  | 0x1C | SHR      | logical right shift: x >> shift                   |
  | 0x1D | SAR      | arithmetic right shift (sign-preserving)          |
  | 0x1E | CLZ      | count of leading zero bits in x (256 if x = 0)    |

  The interpreter has already checked that the stack holds the opcode's inputs.

      iex> EEVM.Interpreter.Instructions.Bitwise.stack_op(0x1B, [4, 1])
      [16]
  """
  @spec stack_op(non_neg_integer(), [non_neg_integer()]) :: [non_neg_integer()]
  def stack_op(0x16, [a, b | rest]), do: [band(a, b) | rest]
  def stack_op(0x17, [a, b | rest]), do: [bor(a, b) | rest]
  def stack_op(0x18, [a, b | rest]), do: [bxor(a, b) | rest]
  def stack_op(0x19, [a | rest]), do: [band(bnot(a), @max_uint256) | rest]

  # BYTE: big-endian byte extraction; byte 0 is the most significant.
  def stack_op(0x1A, [i, x | rest]) when i < 32, do: [band(x >>> ((31 - i) * 8), 0xFF) | rest]
  def stack_op(0x1A, [_i, _x | rest]), do: [0 | rest]

  # SHL and SHR (EIP-145): shifting by 256 or more leaves no original bits.
  def stack_op(0x1B, [shift, _value | rest]) when shift >= 256, do: [0 | rest]
  def stack_op(0x1B, [shift, value | rest]), do: [band(value <<< shift, @max_uint256) | rest]
  def stack_op(0x1C, [shift, _value | rest]) when shift >= 256, do: [0 | rest]
  def stack_op(0x1C, [shift, value | rest]), do: [value >>> shift | rest]

  # SAR (EIP-145): shifting the signed value makes `>>>` fill the vacated high
  # bits with the sign bit. By 256 or more, a negative value becomes -1.
  def stack_op(0x1D, [shift, value | rest]) do
    signed = Helpers.to_signed(value)

    result =
      cond do
        shift >= 256 and signed < 0 -> @max_uint256
        shift >= 256 -> 0
        true -> Helpers.to_unsigned(signed >>> shift)
      end

    [result | rest]
  end

  # CLZ (EIP-7939, Osaka+): the number of leading zero bits in the 256-bit
  # word, so CLZ(0) = 256 and CLZ(x) = 0 when the top bit is set.
  def stack_op(0x1E, [x | rest]), do: [count_leading_zeros(<<x::256>>, 0) | rest]

  defp count_leading_zeros(<<0::1, rest::bitstring>>, count),
    do: count_leading_zeros(rest, count + 1)

  defp count_leading_zeros(_bits, count), do: count
end
