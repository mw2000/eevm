defmodule EEVM.TestSupport.MachineHelpers do
  @moduledoc """
  Runs bytecode on the internal interpreter and reads its final machine
  state, for opcode-level tests that inspect frames, substate, and status.
  """

  alias EEVM.Block.Bloom
  alias EEVM.Interpreter
  alias EEVM.Interpreter.{MachineState, Stack}
  alias EEVM.Tracer

  @spec run_code(binary(), keyword()) :: MachineState.t()
  def run_code(code, opts \\ []), do: Interpreter.run(code, opts)

  @spec trace_code(binary(), keyword()) :: {MachineState.t(), Tracer.t()}
  def trace_code(code, opts \\ []) do
    state = Interpreter.run(code, Keyword.put(opts, :tracer, Tracer.new()))
    {state, state.tracer}
  end

  @spec stack_values(MachineState.t()) :: [non_neg_integer()]
  def stack_values(%MachineState{} = state), do: Stack.to_list(state.frame.stack)

  @spec logs(MachineState.t()) :: [map()]
  def logs(%MachineState{} = state), do: Enum.reverse(state.substate.logs)

  @spec logs_bloom(MachineState.t()) :: Bloom.t()
  def logs_bloom(%MachineState{} = state), do: Bloom.from_logs(state.substate.logs)
end
