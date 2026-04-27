defmodule EEVM.Interpreter.Instructions.Arithmetic do
  @moduledoc """
  Arithmetic opcodes: ADD, MUL, SUB, DIV, SDIV, MOD, SMOD, ADDMOD, MULMOD, EXP, SIGNEXTEND.

  Operands are uint256. Overflow wraps mod 2^256 (enforced with a band mask
  after each op). Division and modulo by zero return 0 instead of trapping.
  SDIV/SMOD reinterpret operands as two's-complement signed 256-bit ints.
  ADDMOD/MULMOD compute the unbounded sum/product before reducing mod n —
  Elixir's bignums avoid the intermediate overflow. EXP has dynamic gas
  proportional to the byte-length of the exponent (`EEVM.Gas.Dynamic`).
  """
  import Bitwise

  alias EEVM.Interpreter.{MachineState, Stack}
  alias EEVM.Gas.Dynamic
  alias EEVM.Interpreter.Instructions.Helpers

  @max_uint256 (1 <<< 256) - 1

  @doc """
  Executes one arithmetic opcode against `state` and advances `pc`.

  | Byte | Op         | Effect                            |
  |------|------------|-----------------------------------|
  | 0x01 | ADD        | `(a + b) mod 2^256`              |
  | 0x02 | MUL        | `(a * b) mod 2^256`              |
  | 0x03 | SUB        | `(a - b) mod 2^256`              |
  | 0x04 | DIV        | `a / b`, 0 on `b == 0`           |
  | 0x05 | SDIV       | signed `a / b`, 0 on `b == 0`    |
  | 0x06 | MOD        | `a mod b`, 0 on `b == 0`         |
  | 0x07 | SMOD       | signed `a mod b`, 0 on `b == 0`  |
  | 0x08 | ADDMOD     | `(a + b) mod n`, 0 on `n == 0`   |
  | 0x09 | MULMOD     | `(a * b) mod n`, 0 on `n == 0`   |
  | 0x0A | EXP        | `a^b mod 2^256`                   |
  | 0x0B | SIGNEXTEND | sign-extend `x` from byte `b`    |
  """
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x01, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1),
         result = band(a + b, @max_uint256),
         {:ok, s3} <- Stack.push(s2, result) do
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x02, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1),
         result = band(a * b, @max_uint256),
         {:ok, s3} <- Stack.push(s2, result) do
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x03, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1),
         result = band(a - b, @max_uint256),
         {:ok, s3} <- Stack.push(s2, result) do
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x04, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = if b == 0, do: 0, else: div(a, b)
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SDIV truncates toward zero. The EVM defines `-2^255 / -1 = -2^255` (the
  # signed-overflow case) — preserved here because `to_signed/to_unsigned`
  # round-trips that bit pattern.
  def execute(0x05, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result =
        if b == 0 do
          0
        else
          sa = Helpers.to_signed(a)
          sb = Helpers.to_signed(b)
          Helpers.to_unsigned(div(sa, sb))
        end

      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x06, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = if b == 0, do: 0, else: rem(a, b)
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SMOD: result takes the sign of the dividend (matches `rem/2`).
  def execute(0x07, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result =
        if b == 0 do
          0
        else
          sa = Helpers.to_signed(a)
          sb = Helpers.to_signed(b)
          Helpers.to_unsigned(rem(sa, sb))
        end

      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x08, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1),
         {:ok, n, s3} <- Stack.pop(s2) do
      result = if n == 0, do: 0, else: rem(a + b, n)
      {:ok, s4} = Stack.push(s3, result)
      {:ok, %{state | stack: s4} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x09, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1),
         {:ok, n, s3} <- Stack.pop(s2) do
      result = if n == 0, do: 0, else: rem(a * b, n)
      {:ok, s4} = Stack.push(s3, result)
      {:ok, %{state | stack: s4} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x0A, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s2}, Dynamic.exp_dynamic_cost(b)) do
      result = Helpers.mod_pow(a, b, @max_uint256 + 1)
      {:ok, s3} = Stack.push(state_after_gas.stack, result)
      {:ok, %{state_after_gas | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  # SIGNEXTEND: treat `x` as a `(b+1)`-byte signed integer and extend to 256
  # bits. `b >= 31` returns `x` unchanged.
  def execute(0x0B, state) do
    with {:ok, b, s1} <- Stack.pop(state.stack),
         {:ok, x, s2} <- Stack.pop(s1) do
      result =
        if b < 31 do
          bit = b * 8 + 7
          mask = (1 <<< bit) - 1

          if (x >>> bit &&& 1) == 1 do
            band(x ||| Bitwise.bnot(mask), @max_uint256)
          else
            band(x, mask)
          end
        else
          x
        end

      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
