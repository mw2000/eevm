defmodule EEVM.Interpreter.Instructions.Helpers do
  @moduledoc """
  Shared opcode primitives: stack-poppers for binary/comparison/bitwise ops,
  signed/unsigned uint256 conversion, modular exponentiation, push-and-advance,
  and JUMPDEST validity.
  """
  import Bitwise

  alias EEVM.Interpreter.{MachineState, Stack}

  @max_uint256 (1 <<< 256) - 1
  @sign_bit 1 <<< 255

  @doc """
  Pops `a` and `b`, pushes `1` if `fun.(a, b)` is true else `0`. Operands are uint256.
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
  Like `comparison_op/2` but converts both operands to two's-complement signed integers first.
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
  Pops `a` and `b`, pushes `fun.(a, b)`. The result must already fit in uint256.
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

  @doc "Reinterprets a uint256 as a two's-complement signed integer."
  @spec to_signed(non_neg_integer()) :: integer()
  def to_signed(value) when value >= @sign_bit, do: value - (@max_uint256 + 1)
  def to_signed(value), do: value

  @doc "Inverse of `to_signed/1`: maps signed integers into the uint256 range."
  @spec to_unsigned(integer()) :: non_neg_integer()

  def to_unsigned(value) when value < 0, do: value + @max_uint256 + 1
  def to_unsigned(value), do: value

  @doc """
  `base^exp mod m` via square-and-multiply (O(log exp)). Used by EXP.
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

  @doc "Pushes `value` and advances `pc` by 1."
  @spec push_value(MachineState.t(), non_neg_integer()) ::
          {:ok, MachineState.t()}
  def push_value(state, value) do
    {:ok, new_stack} = Stack.push(state.stack, value)
    {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}
  end

  @doc """
  Checks whether `dest` is a JUMPDEST byte (0x5B) in `code`.

  The PUSH-immediate-data exclusion required by the spec is enforced upstream
  in the interpreter dispatch table; this only verifies the byte value at `dest`.
  """
  @spec valid_jumpdest?(binary(), non_neg_integer()) :: boolean()
  def valid_jumpdest?(code, dest) when dest < byte_size(code) do
    :binary.at(code, dest) == 0x5B
  end

  def valid_jumpdest?(_code, _dest), do: false
end
