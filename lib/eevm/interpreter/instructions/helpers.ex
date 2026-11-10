defmodule EEVM.Interpreter.Instructions.Helpers do
  @moduledoc """
  Shared utilities for opcode implementations.

  Provides:

  - Stack-pop / push helpers for the common pop-pop-compute-push shape used
    by arithmetic, comparison, and bitwise opcodes.
  - Two's-complement conversion (`to_signed/1`, `to_unsigned/1`) bridging
    the uint256 stack with signed opcodes (SLT, SGT, SDIV, SMOD, SAR).
  - `mod_pow/3`, square-and-multiply modular exponentiation used by EXP.
  - `check_jumpdest/2` for JUMP / JUMPI destination validation.
  """
  import Bitwise

  alias EEVM.Interpreter.{MachineState, Stack}
  alias EEVM.Interpreter.MachineState.Frame

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
    with {:ok, a, s1} <- Stack.pop(state.frame.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = if fun.(a, b), do: 1, else: 0
      {:ok, s3} = Stack.push(s2, result)
      {:ok, state |> MachineState.update_frame(&%{&1 | stack: s3}) |> MachineState.advance_pc()}
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
    with {:ok, a, s1} <- Stack.pop(state.frame.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = if fun.(to_signed(a), to_signed(b)), do: 1, else: 0
      {:ok, s3} = Stack.push(s2, result)
      {:ok, state |> MachineState.update_frame(&%{&1 | stack: s3}) |> MachineState.advance_pc()}
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
    with {:ok, a, s1} <- Stack.pop(state.frame.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = fun.(a, b)
      {:ok, s3} = Stack.push(s2, result)
      {:ok, state |> MachineState.update_frame(&%{&1 | stack: s3}) |> MachineState.advance_pc()}
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
    {:ok, new_stack} = Stack.push(state.frame.stack, value)

    {:ok,
     state |> MachineState.update_frame(&%{&1 | stack: new_stack}) |> MachineState.advance_pc()}
  end

  @doc """
  Checks that `dest` is a valid jump destination in the frame's code: a
  JUMPDEST (0x5B) opcode, not a 0x5B byte inside PUSH1–PUSH32 data (Yellow
  Paper §9.4.3).

  The code is analysed once per transaction: the frame's first JUMP/JUMPI
  takes the code's JUMPDEST map from `state.substate.jumpdest_cache`, or
  builds it, and keeps it in `frame.jumpdests`, so later jumps cost one
  `:binary.at/2`.

  Returns `{:ok, state}` (with the map filled in) or
  `{:error, :invalid_jump_destination, state}`.

      iex> state = EEVM.Interpreter.MachineState.new(<<0x60, 0x5B, 0x5B>>)
      iex> {:ok, _} = EEVM.Interpreter.Instructions.Helpers.check_jumpdest(state, 2)
      iex> {:error, :invalid_jump_destination, _} =
      ...>   EEVM.Interpreter.Instructions.Helpers.check_jumpdest(state, 1)
  """
  @spec check_jumpdest(MachineState.t(), non_neg_integer()) ::
          {:ok, MachineState.t()} | {:error, :invalid_jump_destination, MachineState.t()}
  def check_jumpdest(%MachineState{frame: %Frame{jumpdests: jumpdests}} = state, dest)
      when is_binary(jumpdests) do
    if dest < byte_size(jumpdests) and :binary.at(jumpdests, dest) == 1,
      do: {:ok, state},
      else: {:error, :invalid_jump_destination, state}
  end

  def check_jumpdest(%MachineState{frame: %Frame{code: code}} = state, dest) do
    {jumpdests, cache} =
      case state.substate.jumpdest_cache do
        %{^code => jumpdests} = cache ->
          {jumpdests, cache}

        cache ->
          jumpdests = jumpdest_map(code, <<>>)
          {jumpdests, Map.put(cache, code, jumpdests)}
      end

    check_jumpdest(
      %{
        state
        | frame: %{state.frame | jumpdests: jumpdests},
          substate: %{state.substate | jumpdest_cache: cache}
      },
      dest
    )
  end

  # One byte per code byte: 1 where a JUMPDEST opcode starts, else 0. A byte
  # per position rather than a bit keeps the check a single `:binary.at/2`.
  # PUSH1–PUSH32 (0x60–0x7F) immediates are skipped, including a truncated
  # one at the end of the code.
  defp jumpdest_map(<<0x5B, rest::binary>>, acc), do: jumpdest_map(rest, <<acc::binary, 1>>)

  defp jumpdest_map(<<op, rest::binary>>, acc) when op in 0x60..0x7F do
    n = op - 0x5F

    case rest do
      <<_::binary-size(n), rest::binary>> ->
        jumpdest_map(rest, <<acc::binary, 0::size((n + 1) * 8)>>)

      _ ->
        <<acc::binary, 0::size((byte_size(rest) + 1) * 8)>>
    end
  end

  defp jumpdest_map(<<_, rest::binary>>, acc), do: jumpdest_map(rest, <<acc::binary, 0>>)
  defp jumpdest_map(<<>>, acc), do: acc
end
