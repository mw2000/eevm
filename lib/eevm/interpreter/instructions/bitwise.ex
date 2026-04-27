defmodule EEVM.Interpreter.Instructions.Bitwise do
  @moduledoc """
  Bitwise opcodes: AND, OR, XOR, NOT, BYTE, SHL, SHR, SAR.

  All operate on full 256-bit values. NOT is the 256-bit complement. BYTE is
  big-endian (index 0 = MSB; index ≥ 32 returns 0). SHL/SHR/SAR (Constantinople,
  EIP-145) return 0 when `shift ≥ 256`; SAR returns -1 in that case if the
  value is negative.
  """
  import Bitwise

  alias EEVM.Interpreter.{MachineState, Stack}
  alias EEVM.Interpreter.Instructions.Helpers

  @max_uint256 (1 <<< 256) - 1

  @doc """
  Executes one bitwise opcode against `state` and advances `pc`.

  | Byte | Op   | Effect                                  |
  |------|------|-----------------------------------------|
  | 0x16 | AND  | `a & b`                                 |
  | 0x17 | OR   | `a | b`                                 |
  | 0x18 | XOR  | `a ^ b`                                 |
  | 0x19 | NOT  | bitwise complement of `a`               |
  | 0x1A | BYTE | byte `i` of `x` (big-endian, 0 = MSB)   |
  | 0x1B | SHL  | logical left shift                      |
  | 0x1C | SHR  | logical right shift                     |
  | 0x1D | SAR  | arithmetic right shift (sign-preserving)|
  """
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x16, state), do: Helpers.bitwise_op(state, &band/2)
  def execute(0x17, state), do: Helpers.bitwise_op(state, &bor/2)
  def execute(0x18, state), do: Helpers.bitwise_op(state, &bxor/2)

  def execute(0x19, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack) do
      result = band(Bitwise.bnot(a), @max_uint256)
      {:ok, s2} = Stack.push(s1, result)
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x1A, state) do
    with {:ok, i, s1} <- Stack.pop(state.stack),
         {:ok, x, s2} <- Stack.pop(s1) do
      result =
        if i < 32 do
          shift = (31 - i) * 8
          band(x >>> shift, 0xFF)
        else
          0
        end

      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x1B, state) do
    with {:ok, shift, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      result = if shift >= 256, do: 0, else: band(value <<< shift, @max_uint256)
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x1C, state) do
    with {:ok, shift, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      result = if shift >= 256, do: 0, else: value >>> shift
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SAR: convert to signed first so `>>>` fills vacated high bits with 1s for
  # negative values; clamp to `-1` (all-ones uint256) when `shift >= 256`.
  def execute(0x1D, state) do
    with {:ok, shift, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      signed = Helpers.to_signed(value)

      result =
        cond do
          shift >= 256 and signed < 0 -> @max_uint256
          shift >= 256 -> 0
          true -> Helpers.to_unsigned(signed >>> shift)
        end

      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
