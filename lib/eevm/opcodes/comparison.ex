defmodule EEVM.Opcodes.Comparison do
  @moduledoc """
  EVM comparison opcodes: LT, GT, SLT, SGT, EQ, ISZERO.

  ## EVM Concepts

  Comparison opcodes consume their operands and push a boolean result as either
  1 (true) or 0 (false). The EVM has no native boolean type.

  Key behaviors:

  1. **Unsigned comparisons** — LT, GT, and EQ treat both operands as uint256.
     `1 < 2` is true; `max_uint256 < 0` is false.
  2. **Signed comparisons** — SLT and SGT interpret operands as two's complement
     signed integers. The high bit is the sign bit, so `max_uint256` is -1.
  3. **ISZERO is unary** — it pops one value and pushes 1 if it is zero, 0
     otherwise. It's also used to negate a boolean (ISZERO of a comparison result).

  ## Elixir Learning Notes

  - Passing comparison functions as arguments (`&Kernel.</2`) is higher-order
    programming — the helpers module does the boilerplate and we just supply
    the predicate.
  - `&Kernel.</2` captures the less-than operator as an anonymous function.
    The `/2` means it takes two arguments.
  """
  alias EEVM.{MachineState, Stack}
  alias EEVM.Opcodes.Helpers


  @doc """
  Dispatches and executes a comparison opcode.

  | Byte | Mnemonic | Operation                                   |
  |------|----------|---------------------------------------------|
  | 0x10 | LT       | 1 if a < b (unsigned), else 0               |
  | 0x11 | GT       | 1 if a > b (unsigned), else 0               |
  | 0x12 | SLT      | 1 if a < b (signed two's complement), else 0|
  | 0x13 | SGT      | 1 if a > b (signed two's complement), else 0|
  | 0x14 | EQ       | 1 if a == b, else 0                         |
  | 0x15 | ISZERO   | 1 if a == 0, else 0 (unary)                 |

  Returns `{:ok, new_state}` on success, `{:error, reason, state}` on failure.
  """
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x10, state), do: Helpers.comparison_op(state, &Kernel.</2)
  def execute(0x11, state), do: Helpers.comparison_op(state, &Kernel.>/2)
  def execute(0x12, state), do: Helpers.signed_comparison_op(state, &Kernel.</2)
  def execute(0x13, state), do: Helpers.signed_comparison_op(state, &Kernel.>/2)
  def execute(0x14, state), do: Helpers.comparison_op(state, &Kernel.==/2)

  def execute(0x15, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack) do
      result = if a == 0, do: 1, else: 0
      {:ok, s2} = Stack.push(s1, result)
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
