defmodule EEVM.Interpreter.Instructions.Comparison do
  @moduledoc """
  Comparison opcodes: LT, GT, SLT, SGT, EQ, ISZERO.

  Push 1 for true, 0 for false. LT/GT/EQ are unsigned uint256; SLT/SGT
  reinterpret the high bit as a sign (`max_uint256` is -1). ISZERO is unary
  and is the canonical way to negate a boolean result.
  """
  alias EEVM.Interpreter.{MachineState, Stack}
  alias EEVM.Interpreter.Instructions.Helpers

  @doc """
  Executes one comparison opcode against `state` and advances `pc`.

  | Byte | Op     | Effect                                |
  |------|--------|---------------------------------------|
  | 0x10 | LT     | unsigned `a < b`                       |
  | 0x11 | GT     | unsigned `a > b`                       |
  | 0x12 | SLT    | signed `a < b`                         |
  | 0x13 | SGT    | signed `a > b`                         |
  | 0x14 | EQ     | `a == b`                               |
  | 0x15 | ISZERO | unary `a == 0`                         |
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
