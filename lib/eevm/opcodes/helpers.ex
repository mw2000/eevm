defmodule EEVM.Opcodes.Helpers do
  @moduledoc """
  Shared utilities for opcode implementations.

  ## EVM Concepts

  Many opcode categories (arithmetic, comparison, bitwise) share the same
  structural patterns: pop operands, compute, push result, advance PC. Pulling
  those patterns into helpers keeps each opcode module focused on what makes it
  unique and avoids duplicating error-handling boilerplate.

  Key responsibilities:

  1. **Signed arithmetic** — the EVM stack stores everything as uint256, but
     several opcodes (SLT, SGT, SDIV, SMOD, SAR) interpret values as signed.
     Two's complement conversion is the bridge between the two representations.
  2. **Modular exponentiation** — the EXP opcode raises a base to an exponent
     mod 2^256. A naive loop would be impossibly slow for large exponents, so
     we use square-and-multiply (binary exponentiation).
  3. **Jump validation** — JUMP and JUMPI must land on a JUMPDEST (0x5B) byte.
     Any other destination is invalid and halts execution.

  ## Elixir Learning Notes

  - These helpers are `def` (public) so any opcode module can call them.
    Each module keeps its own private helpers private (`defp`) to avoid
    polluting the shared namespace.
  - `with` chains let us sequence fallible stack operations cleanly. If any
    step returns `{:error, reason}`, execution jumps to the `else` clause.
  - Pattern matching in `to_signed/1` guards (`when value >= @sign_bit`)
    avoids a conditional branch — the correct clause is selected at call time.
  """
  import Bitwise

  alias EEVM.{MachineState, Stack}

  @max_uint256 (1 <<< 256) - 1
  @sign_bit 1 <<< 255

  @doc """
  Pops two values from the stack, applies a comparison, and pushes 1 or 0.

  Used by LT (0x10), GT (0x11), and EQ (0x14). The comparison function `fun`
  receives `a` (first pop) and `b` (second pop) as unsigned integers.
  """
  @spec comparison_op(MachineState.t(), (non_neg_integer(), non_neg_integer() -> boolean())) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def comparison_op(state, fun) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = if fun.(a, b), do: 1, else: 0
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end


  @doc """
  Same as `comparison_op/2` but interprets both values as signed 256-bit integers.

  Used by SLT (0x12) and SGT (0x13). Converts each uint256 operand to two's
  complement before applying the comparison, then pushes 1 or 0.
  """
  @spec signed_comparison_op(
          MachineState.t(),
          (integer(), integer() -> boolean())
        ) :: {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def signed_comparison_op(state, fun) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = if fun.(to_signed(a), to_signed(b)), do: 1, else: 0
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end


  @doc """
  Pops two values, applies a bitwise function, and pushes the result.

  Used by AND (0x16), OR (0x17), and XOR (0x18). The function `fun` receives
  `a` and `b` as uint256 values and must return a uint256.
  """
  @spec bitwise_op(MachineState.t(), (non_neg_integer(), non_neg_integer() -> non_neg_integer())) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def bitwise_op(state, fun) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = fun.(a, b)
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end


  @doc """
  Converts a uint256 value to a signed 256-bit integer (two's complement).

  Any value with the 255th bit set (>= 2^255) is treated as negative. For
  example, the uint256 representation of -1 is 2^256 - 1 (all bits set).
  """
  @spec to_signed(non_neg_integer()) :: integer()
  def to_signed(value) when value >= @sign_bit, do: value - (@max_uint256 + 1)
  def to_signed(value), do: value

  @doc """
  Converts a signed integer back to its uint256 (two's complement) representation.

  Negative values are mapped to the upper half of the uint256 range. Positive
  values (and zero) pass through unchanged.
  """
  @spec to_unsigned(integer()) :: non_neg_integer()

  def to_unsigned(value) when value < 0, do: value + @max_uint256 + 1
  def to_unsigned(value), do: value

  @doc """
  Computes `base^exp mod m` using square-and-multiply (binary exponentiation).

  Used by EXP (0x0A). The naive approach of multiplying `base` by itself `exp`
  times would be O(exp) — unusable for 256-bit exponents. Square-and-multiply
  is O(log exp), making it practical even for large values.
  """
  @spec mod_pow(non_neg_integer(), non_neg_integer(), pos_integer()) :: non_neg_integer()

  def mod_pow(_base, 0, _m), do: 1
  def mod_pow(base, 1, m), do: rem(base, m)

  def mod_pow(base, exp, m) do
    half = mod_pow(base, div(exp, 2), m)
    half_sq = rem(half * half, m)

    if rem(exp, 2) == 0 do
      half_sq
    else
      rem(half_sq * rem(base, m), m)
    end
  end


  @doc """
  Pushes a value onto the stack and advances the program counter by 1.

  This is the final step in almost every opcode: after computing a result,
  push it and move to the next instruction.
  """
  @spec push_value(MachineState.t(), non_neg_integer()) ::
          {:ok, MachineState.t()}
  def push_value(state, value) do
    {:ok, new_stack} = Stack.push(state.stack, value)
    {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}
  end


  @doc """
  Returns true if `dest` is a valid JUMPDEST in the given bytecode.

  A valid jump destination must be the opcode byte 0x5B at position `dest`.
  Bytes that are part of PUSH data (e.g., the `0x5B` argument to PUSH1 0x5B)
  are not valid destinations, though this implementation checks only the byte
  value — full push-data exclusion happens at the executor level.
  """
  @spec valid_jumpdest?(binary(), non_neg_integer()) :: boolean()
  def valid_jumpdest?(code, dest) when dest < byte_size(code) do
    :binary.at(code, dest) == 0x5B
  end

  def valid_jumpdest?(_code, _dest), do: false
end
