defmodule EEVM.TestSupport.MachineHelpers do
  @moduledoc """
  Runs bytecode on the internal interpreter and reads its final machine
  state, for opcode-level tests that inspect frames, substate, and status.
  """

  alias EEVM.Block.Bloom
  alias EEVM.Interpreter
  alias EEVM.Interpreter.{InstructionTable, MachineState, Stack}
  alias EEVM.Tracer

  @spec run_code(binary(), keyword()) :: MachineState.t()
  def run_code(code, opts \\ []), do: Interpreter.run(code, opts)

  @doc """
  Runs `code` as `run_code/2` does, kept undecoded: it is padded with STOPs to
  24 KB, the EIP-170 limit. Running off the end of code is a STOP already, so
  the padding changes nothing the code does, but the frame decodes only after
  it has used about 50,000 gas (#210).
  """
  @spec run_undecoded(binary(), keyword()) :: MachineState.t()
  def run_undecoded(code, opts \\ []) do
    padded = code <> :binary.copy(<<0x00>>, 24_576 - byte_size(code))
    state = Interpreter.run(padded, opts)

    unless match?({:undecoded, _, _}, state.frame.program),
      do: raise("run_undecoded/2: the code was decoded")

    state
  end

  @doc """
  Runs `code` as `run_code/2` does, decoded from the start, as when a frame
  earlier in the transaction decoded it (#210).
  """
  @spec run_decoded(binary(), keyword()) :: MachineState.t()
  def run_decoded(code, opts \\ []) do
    program =
      InstructionTable.decode(code, MachineState.new(code, opts).env.instruction_table, false)

    Interpreter.run(code, Keyword.put(opts, :program_cache, %{code => program}))
  end

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
