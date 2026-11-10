defmodule EEVM.Interpreter.Instructions.Arithmetic do
  @moduledoc "EVM arithmetic opcodes: ADD, MUL, SUB, DIV, SDIV, MOD, SMOD, ADDMOD, MULMOD, EXP, SIGNEXTEND."
  import Bitwise

  alias EEVM.Gas.Dynamic
  alias EEVM.Interpreter.Instructions.Helpers
  alias EEVM.Interpreter.{MachineState, Stack}

  @max_uint256 (1 <<< 256) - 1

  @doc """
  Applies an arithmetic opcode to the stack (a list, top first) and returns the new stack.

  | Byte | Mnemonic  | Operation                          |
  |------|-----------|------------------------------------|
  | 0x01 | ADD       | `(a + b) mod 2^256`                |
  | 0x02 | MUL       | `(a * b) mod 2^256`                |
  | 0x03 | SUB       | `(a - b) mod 2^256`                |
  | 0x04 | DIV       | `a / b` (0 if b == 0)              |
  | 0x05 | SDIV      | signed division (0 if b == 0)      |
  | 0x06 | MOD       | `a mod b` (0 if b == 0)            |
  | 0x07 | SMOD      | signed modulo (0 if b == 0)        |
  | 0x08 | ADDMOD    | `(a + b) mod n` (0 if n == 0)      |
  | 0x09 | MULMOD    | `(a * b) mod n` (0 if n == 0)      |
  | 0x0B | SIGNEXTEND| sign-extend x from byte width b    |

  The interpreter has already checked that the stack holds the opcode's inputs.
  EXP is not here: its gas depends on the exponent, so it goes through `execute/2`.

      iex> EEVM.Interpreter.Instructions.Arithmetic.stack_op(0x03, [1, 3, 7])
      [115792089237316195423570985008687907853269984665640564039457584007913129639934, 7]
  """
  @spec stack_op(non_neg_integer(), [non_neg_integer()]) :: [non_neg_integer()]
  def stack_op(0x01, [a, b | rest]), do: [band(a + b, @max_uint256) | rest]
  def stack_op(0x02, [a, b | rest]), do: [band(a * b, @max_uint256) | rest]
  def stack_op(0x03, [a, b | rest]), do: [band(a - b, @max_uint256) | rest]
  def stack_op(0x04, [_a, 0 | rest]), do: [0 | rest]
  def stack_op(0x04, [a, b | rest]), do: [div(a, b) | rest]

  # SDIV: signed division. Elixir's `div/2` truncates toward zero, matching the
  # EVM. -2^255 / -1 gives 2^255, whose uint256 encoding is -2^255, the result
  # the EVM defines.
  def stack_op(0x05, [_a, 0 | rest]), do: [0 | rest]

  def stack_op(0x05, [a, b | rest]),
    do: [Helpers.to_unsigned(div(Helpers.to_signed(a), Helpers.to_signed(b))) | rest]

  def stack_op(0x06, [_a, 0 | rest]), do: [0 | rest]
  def stack_op(0x06, [a, b | rest]), do: [rem(a, b) | rest]

  # SMOD: signed modulo. The result takes the sign of the dividend, as
  # Elixir's `rem/2` does.
  def stack_op(0x07, [_a, 0 | rest]), do: [0 | rest]

  def stack_op(0x07, [a, b | rest]),
    do: [Helpers.to_unsigned(rem(Helpers.to_signed(a), Helpers.to_signed(b))) | rest]

  def stack_op(0x08, [_a, _b, 0 | rest]), do: [0 | rest]
  def stack_op(0x08, [a, b, n | rest]), do: [rem(a + b, n) | rest]
  def stack_op(0x09, [_a, _b, 0 | rest]), do: [0 | rest]
  def stack_op(0x09, [a, b, n | rest]), do: [rem(a * b, n) | rest]

  # SIGNEXTEND: treats x as a (b+1)-byte signed integer and sign-extends it to
  # 256 bits. For b >= 31 x is already full width. Otherwise, if the sign bit
  # of byte b is set, every higher bit is set; if not, they are cleared.
  def stack_op(0x0B, [b, x | rest]) when b >= 31, do: [x | rest]

  def stack_op(0x0B, [b, x | rest]) do
    bit = b * 8 + 7
    mask = (1 <<< bit) - 1

    if (x >>> bit &&& 1) == 1,
      do: [band(x ||| bnot(mask), @max_uint256) | rest],
      else: [band(x, mask) | rest]
  end

  @doc """
  Executes EXP (0x0A), which charges `Gas.Dynamic.exp_dynamic_cost/2` for its
  exponent on top of the static cost (EIP-160).

  Returns `{:ok, new_state}` on success, `{:error, reason, state}` on failure.
  """
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x0A, state) do
    with {:ok, a, s1} <- Stack.pop(state.frame.stack),
         {:ok, b, s2} <- Stack.pop(s1),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(
             MachineState.update_frame(state, &%{&1 | stack: s2}),
             Dynamic.exp_dynamic_cost(b, state.env.config.hardfork)
           ) do
      result = Helpers.mod_pow(a, b, @max_uint256 + 1)
      {:ok, s3} = Stack.push(state_after_gas.frame.stack, result)

      {:ok,
       state_after_gas
       |> MachineState.update_frame(&%{&1 | stack: s3})
       |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
