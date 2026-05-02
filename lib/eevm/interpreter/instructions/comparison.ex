defmodule EEVM.Interpreter.Instructions.Comparison do
  @moduledoc "EVM comparison opcodes: LT, GT, SLT, SGT, EQ, ISZERO."
  alias EEVM.Interpreter.Instructions.Helpers
  alias EEVM.Interpreter.{MachineState, Stack}

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
    with {:ok, a, s1} <- Stack.pop(state.frame.stack) do
      result = if a == 0, do: 1, else: 0
      {:ok, s2} = Stack.push(s1, result)
      {:ok, state |> MachineState.update_frame(&%{&1 | stack: s2}) |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
