defmodule EEVM.Opcodes.Arithmetic do
  @moduledoc """
  EVM arithmetic opcodes: ADD, MUL, SUB, DIV, SDIV, MOD, SMOD, ADDMOD, MULMOD, EXP, SIGNEXTEND.

  ## EVM Concepts

  All arithmetic operates on unsigned 256-bit integers (uint256). Overflow wraps
  silently modulo 2^256 — there are no exceptions or traps. This means, for
  example, that `max_uint256 + 1 == 0`.

  Key rules:

  1. **Wrapping arithmetic** — ADD, MUL, SUB all wrap mod 2^256. We enforce
     this with a bitwise AND mask after each operation.
  2. **Division by zero returns 0** — unlike most languages, DIV, SDIV, MOD,
     and SMOD all return 0 when the divisor is zero. No exception is raised.
  3. **Signed operations use two's complement** — SDIV and SMOD interpret
     operands as signed 256-bit integers before dividing.
  4. **ADDMOD and MULMOD use unlimited precision** — they compute `(a + b) mod n`
     and `(a * b) mod n` without the intermediate result wrapping at 2^256.
     Elixir's arbitrary-precision integers make this free.
  5. **EXP has dynamic gas** — cost grows with the byte length of the exponent.

  ## Elixir Learning Notes

  - Elixir integers are arbitrary-precision, so `a * b` never overflows. We
    apply a `band(..., @max_uint256)` mask to truncate to 256 bits explicitly.
  - Each opcode clause is a separate `execute/2` head matched by the opcode byte.
    This is idiomatic pattern matching on function arguments.
  - `with` chains short-circuit on `{:error, reason}` — each line binds a
    variable only if the previous step succeeded.
  """
  import Bitwise

  alias EEVM.{Gas, MachineState, Stack}
  alias EEVM.Opcodes.Helpers

  @max_uint256 (1 <<< 256) - 1

  @doc """
  Dispatches and executes an arithmetic opcode.

  Each clause handles one opcode byte:

  | Byte | Mnemonic  | Operation                          |
  |------|-----------|------------------------------------|
  | 0x01 | ADD       | `(a + b) mod 2^256`               |
  | 0x02 | MUL       | `(a * b) mod 2^256`               |
  | 0x03 | SUB       | `(a - b) mod 2^256`               |
  | 0x04 | DIV       | `a / b` (0 if b == 0)             |
  | 0x05 | SDIV      | signed division (0 if b == 0)     |
  | 0x06 | MOD       | `a mod b` (0 if b == 0)           |
  | 0x07 | SMOD      | signed modulo (0 if b == 0)       |
  | 0x08 | ADDMOD    | `(a + b) mod n` (0 if n == 0)    |
  | 0x09 | MULMOD    | `(a * b) mod n` (0 if n == 0)    |
  | 0x0A | EXP       | `a^b mod 2^256`                   |
  | 0x0B | SIGNEXTEND| sign-extend x from byte width b   |

  Returns `{:ok, new_state}` on success, `{:error, reason, state}` on failure.
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

  # SDIV: signed division. Elixir's `div/2` truncates toward zero, matching
  # the EVM spec for SDIV. Special case: -2^255 / -1 would overflow to 2^255
  # (outside the signed 256-bit range), so the EVM defines the result as -2^255.
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

  # SMOD: signed modulo. The result takes the sign of the dividend (a),
  # matching the behavior of Elixir's `rem/2` for negative numbers.
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
           MachineState.consume_gas(%{state | stack: s2}, Gas.exp_dynamic_cost(b)) do
      result = Helpers.mod_pow(a, b, @max_uint256 + 1)
      {:ok, s3} = Stack.push(state_after_gas.stack, result)
      {:ok, %{state_after_gas | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  # SIGNEXTEND: treats x as a (b+1)-byte signed integer and sign-extends it
  # to 256 bits. If b >= 31 the value is already full-width, so x is returned
  # unchanged. Otherwise, if the sign bit of the b-th byte is 1 (negative),
  # all higher bits are set to 1 (bnot mask); if 0 (positive), higher bits
  # are cleared.
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
