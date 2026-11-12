defmodule EEVM.Interpreter.Instructions.Helpers do
  @moduledoc """
  Shared utilities for opcode implementations.

  Provides:

  - Stack-pop / push helpers for the common pop-pop-compute-push shape used
    by arithmetic, comparison, and bitwise opcodes.
  - Two's-complement conversion (`to_signed/1`, `to_unsigned/1`) bridging
    the uint256 stack with signed opcodes (SLT, SGT, SDIV, SMOD, SAR).
  - `mod_pow/3`, square-and-multiply modular exponentiation used by EXP.
  - `pop_address/1` for opcodes that take an address operand.
  - `touch_account/3`, which before EIP-161 creates the accounts a message
    call or fee credit touches. The transaction handler shares it.
  """
  import Bitwise

  alias EEVM.{Database, HardforkConfig}
  alias EEVM.Interpreter.{MachineState, Stack}
  require EEVM.HardforkConfig

  @max_uint256 (1 <<< 256) - 1
  @address_mask (1 <<< 160) - 1
  @sign_bit 1 <<< 255

  @doc """
  Before EIP-161 (Spurious Dragon), touching an account that doesn't exist
  creates it empty, even when no value moves: the target of every message
  call, and the coinbase credited a zero fee (execution-specs Frontier
  `process_message` calls `touch_account`; `process_transaction` sets the
  coinbase balance). From EIP-161 the account is not created, and touched
  empty accounts are deleted when the transaction ends.

  ## Example

      iex> alias EEVM.{Database, HardforkConfig}
      iex> alias EEVM.Interpreter.Instructions.Helpers
      iex> db = EEVM.Database.InMemory.new()
      iex> Database.account_exists?(Helpers.touch_account(db, 0xAB, HardforkConfig.new(:frontier)), 0xAB)
      true
      iex> Database.account_exists?(Helpers.touch_account(db, 0xAB, HardforkConfig.new(:spurious_dragon)), 0xAB)
      false
  """
  @spec touch_account(Database.t(), non_neg_integer(), HardforkConfig.t()) :: Database.t()
  def touch_account(%Database{} = db, address, %HardforkConfig{} = hardfork) do
    if HardforkConfig.enabled?(hardfork, :eip_161) or Database.account_exists?(db, address),
      do: db,
      else: Database.put_account(db, address, %{})
  end

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
  Pops an address operand: the top stack word truncated to its low 160 bits,
  as BALANCE, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH, the CALL family, and
  SELFDESTRUCT read it (Yellow Paper Appendix H, `μs[0] mod 2^160`).

      iex> {:ok, stack} = EEVM.Interpreter.Stack.push(EEVM.Interpreter.Stack.new(), 2 ** 200 + 0xAB)
      iex> {:ok, address, _} = EEVM.Interpreter.Instructions.Helpers.pop_address(stack)
      iex> address
      0xAB
  """
  @spec pop_address(Stack.t()) :: {:ok, non_neg_integer(), Stack.t()} | {:error, atom()}
  def pop_address(stack) do
    with {:ok, word, stack} <- Stack.pop(stack), do: {:ok, word &&& @address_mask, stack}
  end
end
