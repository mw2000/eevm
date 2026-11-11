defmodule Devx.Tracing do
  @moduledoc "Task 4: trace an execution opcode by opcode."

  @doc "Traces `transfer(to, amount)` on `token` and returns the trace and the call's gas used."
  def transfer(db, token, from, to, amount) do
    calldata = EEVM.selector("transfer(address,uint256)") <> <<to::256, amount::256>>
    {:ok, result} = EEVM.call(db, token, calldata, caller: from, tracer: true)
    {result.trace, result.gas_used}
  end

  @doc "Traces raw bytecode and returns the trace and the gas used."
  def run(code) do
    {:ok, result} = EEVM.run(code, tracer: true)
    {result.trace, result.gas_used}
  end

  @doc "The steps of a trace as `{pc, op, stack}`, stack top first."
  def steps(trace), do: for(step <- EEVM.Tracer.steps(trace), do: {step.pc, step.op, step.stack})

  @doc "The `{slot, value}` pairs each SSTORE in `trace` wrote."
  def storage_writes(trace) do
    for %{op: :SSTORE, stack: [slot, value | _]} <- EEVM.Tracer.steps(trace), do: {slot, value}
  end

  @doc "The sum of every step's reported gas cost."
  def total_step_cost(trace),
    do: trace |> EEVM.Tracer.steps() |> Enum.map(& &1.gas_cost) |> Enum.sum()

  @doc "The EIP-3155 JSON lines, to diff against `geth evm --json`."
  def json_lines(trace), do: EEVM.Tracer.to_json_lines(trace)
end
