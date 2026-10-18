defmodule EEVM.Interpreter.Instructions.Bitwise do
  @moduledoc "EVM bitwise opcodes: AND, OR, XOR, NOT, BYTE, SHL, SHR, SAR."
  import Bitwise

  alias EEVM.Interpreter.Instructions.Helpers
  alias EEVM.Interpreter.{MachineState, Stack}

  @max_uint256 (1 <<< 256) - 1

  @doc """
  Dispatches and executes a bitwise opcode.

  | Byte | Mnemonic | Operation                                         |
  |------|----------|---------------------------------------------------|
  | 0x16 | AND      | bitwise AND of a and b                            |
  | 0x17 | OR       | bitwise OR of a and b                             |
  | 0x18 | XOR      | bitwise XOR of a and b                            |
  | 0x19 | NOT      | bitwise complement (all 256 bits flipped)          |
  | 0x1A | BYTE     | byte at index i of x (big-endian, 0 = MSB)        |
  | 0x1B | SHL      | logical left shift: x << shift mod 2^256          |
  | 0x1C | SHR      | logical right shift: x >> shift                   |
  | 0x1D | SAR      | arithmetic right shift (sign-preserving)           |

  Returns `{:ok, new_state}` on success, `{:error, reason, state}` on failure.
  """
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x16, state), do: Helpers.bitwise_op(state, &band/2)
  def execute(0x17, state), do: Helpers.bitwise_op(state, &bor/2)
  def execute(0x18, state), do: Helpers.bitwise_op(state, &bxor/2)

  def execute(0x19, state) do
    with {:ok, a, s1} <- Stack.pop(state.frame.stack) do
      result = band(Bitwise.bnot(a), @max_uint256)
      {:ok, s2} = Stack.push(s1, result)
      {:ok, state |> MachineState.update_frame(&%{&1 | stack: s2}) |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # BYTE: big-endian byte extraction. Byte 0 is the most significant byte.
  # `(31 - i) * 8` computes the right-shift amount so the target byte lands in
  # the lowest 8 bits, then we mask with 0xFF to isolate it.
  def execute(0x1A, state) do
    with {:ok, i, s1} <- Stack.pop(state.frame.stack),
         {:ok, x, s2} <- Stack.pop(s1) do
      result =
        if i < 32 do
          shift = (31 - i) * 8
          band(x >>> shift, 0xFF)
        else
          0
        end

      {:ok, s3} = Stack.push(s2, result)
      {:ok, state |> MachineState.update_frame(&%{&1 | stack: s3}) |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SHL: logical left shift. Shifting by >= 256 must return 0 because no original
  # bits remain. We mask with @max_uint256 after shifting to stay within 256 bits.
  def execute(0x1B, state) do
    with {:ok, shift, s1} <- Stack.pop(state.frame.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      result = if shift >= 256, do: 0, else: band(value <<< shift, @max_uint256)
      {:ok, s3} = Stack.push(s2, result)
      {:ok, state |> MachineState.update_frame(&%{&1 | stack: s3}) |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SHR: logical right shift. Shifting by >= 256 returns 0.
  # Elixir's `>>>` on a non-negative integer is a logical right shift.
  def execute(0x1C, state) do
    with {:ok, shift, s1} <- Stack.pop(state.frame.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      result = if shift >= 256, do: 0, else: value >>> shift
      {:ok, s3} = Stack.push(s2, result)
      {:ok, state |> MachineState.update_frame(&%{&1 | stack: s3}) |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SAR: arithmetic right shift. We convert to signed first so Elixir's `>>>`
  # fills vacated high bits with 1s for negative values. If shift >= 256 and
  # the value is negative, the result is all 1s (@max_uint256, representing -1).
  def execute(0x1D, state) do
    with {:ok, shift, s1} <- Stack.pop(state.frame.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      signed = Helpers.to_signed(value)

      result =
        cond do
          shift >= 256 and signed < 0 -> @max_uint256
          shift >= 256 -> 0
          true -> Helpers.to_unsigned(signed >>> shift)
        end

      {:ok, s3} = Stack.push(s2, result)
      {:ok, state |> MachineState.update_frame(&%{&1 | stack: s3}) |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
