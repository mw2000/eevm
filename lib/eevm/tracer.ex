defmodule EEVM.Tracer do
  @moduledoc """
  Opt-in opcode-level execution tracer.

  Pass `tracer: true` to `EEVM.run/2`, `EEVM.transact/4`, or
  `EEVM.Block.execute/4` and the result's `trace` holds a tracer with one
  `EEVM.Tracer.TraceStep` per executed opcode, in every call frame. Read the
  steps with `steps/1`, or render them with `to_json/1` in the EIP-3155
  format that `geth evm --json` and revm emit, so traces can be diffed
  against theirs.

      iex> {:ok, result} = EEVM.run(<<0x60, 1, 0x60, 2, 0x01, 0x00>>, tracer: true)
      iex> for step <- EEVM.Tracer.steps(result.trace), do: {step.pc, step.op, step.stack}
      [{0, :PUSH1, []}, {2, :PUSH1, [1]}, {4, :ADD, [2, 1]}, {5, :STOP, [3]}]

  ## Gas cost

  A step's `gas_cost` is what geth's structLog reports as `gasCost`: the
  static and dynamic gas the opcode charges, memory expansion included.

  - CALL, CALLCODE, DELEGATECALL, and STATICCALL count the gas they forward
    to the callee, as geth does. The callee's own steps spend it, and what
    the callee leaves comes back to the caller, so the caller's next step
    shows it in `gas_remaining`.
  - CREATE and CREATE2 do not count the gas they forward to the init code,
    as in geth, where the forwarding happens inside the opcode.
  - A step that fails reports the cost it attempted, not the remaining gas
    the failure burns: its static cost when its static gas or stack check
    fails, and what it charged, failing charge included, when it runs out of
    gas while running. INVALID costs 0.

  So when no frame halts exceptionally and nothing is created, a
  transaction's `gas_used` is its intrinsic gas plus the cost of all its
  steps, less the gas each call forwards (the callee's steps count it again),
  less the refund.

  These are the semantics of geth's `core/vm/interpreter.go`, which reports
  the constant gas plus the dynamic gas function's result, and of its
  `makeCallVariantGasCost`, whose dynamic gas includes the forwarded gas.

  ## Performance

  Without `:tracer`, the interpreter skips all trace bookkeeping: no
  snapshot is taken and the tracer branch is a single pattern match.
  """

  alias EEVM.Interpreter.Instructions.Registry

  defmodule TraceStep do
    @moduledoc """
    A single recorded step: one opcode execution in the trace. Every field
    except `error` describes the machine *before* the opcode runs.

    | Field | Description |
    |-------|-------------|
    | `pc` | Program counter of the opcode in its frame's code |
    | `op` | Opcode name as an atom, such as `:SSTORE`; `:UNKNOWN` for an undefined byte |
    | `op_byte` | The opcode byte |
    | `gas_remaining` | Gas left in the frame |
    | `gas_cost` | The gas the opcode charged, static and dynamic, as geth's `gasCost` reports it: a CALL counts the gas it forwards, a CREATE does not (see "Gas cost" in `EEVM.Tracer`) |
    | `stack` | The stack, **top first** (`to_json/1` writes it bottom first, as EIP-3155 does) |
    | `memory_size` | Memory size in bytes |
    | `depth` | Call depth, 0 for the top-level frame (`to_json/1` writes it 1-based, as EIP-3155 does) |
    | `refund` | The gas refund counter |
    | `return_data` | The return-data buffer: the output of the frame's last sub-call |
    | `error` | The halt reason (an `t:EEVM.Error.halt_reason/0`) when this opcode halted the frame, else `nil` |
    """

    @type t :: %__MODULE__{
            pc: non_neg_integer(),
            op: atom(),
            op_byte: non_neg_integer(),
            gas_remaining: non_neg_integer(),
            gas_cost: non_neg_integer(),
            stack: [non_neg_integer()],
            memory_size: non_neg_integer(),
            depth: non_neg_integer(),
            refund: integer(),
            return_data: binary(),
            error: atom() | nil
          }

    defstruct [
      :pc,
      :op,
      :op_byte,
      :gas_remaining,
      :gas_cost,
      :stack,
      :memory_size,
      :depth,
      :refund,
      :return_data,
      :error
    ]
  end

  @type snapshot :: %{
          pc: non_neg_integer(),
          op_byte: non_neg_integer(),
          op: atom(),
          gas: non_neg_integer(),
          stack: [non_neg_integer()],
          memory_size: non_neg_integer(),
          depth: non_neg_integer(),
          refund: integer()
        }

  # A step's cost is known only once the step is over, when its frame reaches
  # its next step or ends. Until then the step is open: `open` holds one
  # `{depth, index, gas_before, settled?}` per frame with an open step,
  # innermost first, where `index` is the step's position in the trace.
  # `settle/3` fixes a cost earlier, before gas that does not count toward it
  # moves (see the moduledoc). `steps` holds the steps newest first; a step's
  # cost goes into it directly while the step is the newest, and into `costs`,
  # by index, once its callee's steps follow it.
  @type t :: %__MODULE__{
          steps: [TraceStep.t()],
          count: non_neg_integer(),
          open: [{non_neg_integer(), non_neg_integer(), non_neg_integer(), boolean()}],
          costs: %{non_neg_integer() => non_neg_integer()}
        }

  defstruct steps: [], count: 0, open: [], costs: %{}

  @doc "Returns an empty tracer. `tracer: true` is shorthand for `tracer: EEVM.Tracer.new()`."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc false
  # Called by the interpreter for each step: records the step about to run.
  # The previous step of the same frame is then over, and costs the gas the
  # frame lost between the two steps, unless `settle/3` fixed its cost.
  @spec record(t(), TraceStep.t()) :: t()
  def record(%__MODULE__{} = tracer, %TraceStep{depth: depth, gas_remaining: gas} = step) do
    {tracer, outer} =
      case tracer.open do
        [{^depth, _index, _gas_before, _settled?} = entry | outer] ->
          {finish(tracer, entry, gas), outer}

        open ->
          {tracer, open}
      end

    %{
      tracer
      | steps: [step | tracer.steps],
        count: tracer.count + 1,
        open: [{depth, tracer.count, gas, false} | outer]
    }
  end

  # The interpreter's hooks: `EEVM.Interpreter.MachineState.settle_trace_cost/1`
  # and `EEVM.Interpreter.run_loop/1` call these.

  # Fixes the cost of the open step of the frame at `depth` as the gas it has
  # charged when `gas` is left. Later changes to the frame's gas, such as gas a
  # callee hands back or the gas an exceptional halt burns, do not change it.
  # Only the first call for a step counts.
  @doc false
  @spec settle(t(), non_neg_integer(), integer()) :: t()
  def settle(%__MODULE__{open: [{depth, index, gas_before, false} | outer]} = tracer, depth, gas) do
    tracer = put_cost(tracer, index, gas_before - gas)
    %{tracer | open: [{depth, index, gas_before, true} | outer]}
  end

  def settle(%__MODULE__{} = tracer, _depth, _gas), do: tracer

  # Ends the frame at `depth`, which has `gas` left: its last step costs the
  # gas the frame lost since that step began, unless `settle/3` fixed it.
  @doc false
  @spec close_frame(t(), non_neg_integer(), non_neg_integer()) :: t()
  def close_frame(%__MODULE__{open: [{depth, _, _, _} = entry | outer]} = tracer, depth, gas),
    do: %{finish(tracer, entry, gas) | open: outer}

  # A frame that recorded no step, such as an empty account's, has none open.
  def close_frame(%__MODULE__{} = tracer, _depth, _gas), do: tracer

  defp finish(tracer, {_depth, _index, _gas_before, true}, _gas_after), do: tracer

  defp finish(tracer, {_depth, index, gas_before, false}, gas_after),
    do: put_cost(tracer, index, gas_before - gas_after)

  defp put_cost(%__MODULE__{count: count, steps: [last | rest]} = tracer, index, cost)
       when index == count - 1,
       do: %{tracer | steps: [%{last | gas_cost: cost} | rest]}

  defp put_cost(%__MODULE__{costs: costs} = tracer, index, cost),
    do: %{tracer | costs: Map.put(costs, index, cost)}

  @doc false
  # Called by the interpreter: marks the most recently recorded step with an error reason.
  @spec set_last_error(t(), atom()) :: t()
  def set_last_error(%__MODULE__{steps: []} = tracer, _reason), do: tracer

  def set_last_error(%__MODULE__{steps: [last | rest]} = tracer, reason) do
    %{tracer | steps: [%{last | error: reason} | rest]}
  end

  @doc "Returns the recorded steps in execution order."
  @spec steps(t()) :: [TraceStep.t()]
  def steps(%__MODULE__{steps: steps, costs: costs}) when costs == %{}, do: Enum.reverse(steps)

  def steps(%__MODULE__{steps: steps, costs: costs}) do
    steps
    |> Enum.reverse()
    |> Enum.with_index(fn step, index ->
      case costs do
        %{^index => cost} -> %{step | gas_cost: cost}
        _ -> step
      end
    end)
  end

  @doc """
  Returns the opcode name atom for a byte, or `:UNKNOWN` for an undefined one.

      iex> EEVM.Tracer.op_name(0x01)
      :ADD
      iex> EEVM.Tracer.op_name(0x0C)
      :UNKNOWN
  """
  @spec op_name(non_neg_integer()) :: atom()
  # One clause per opcode, built from the Registry at compile time, so tracing
  # creates no atoms at run time.
  for opcode <- 0..255, {:ok, %{name: name}} <- [Registry.info(opcode)] do
    def op_name(unquote(opcode)), do: unquote(String.to_atom(name))
  end

  def op_name(_opcode), do: :UNKNOWN

  @doc """
  Renders the trace as EIP-3155 / geth `--json` compatible JSON lines.

  Returns a list of JSON-encoded strings, one per step. Join with newlines
  for geth-style output.
  """
  @spec to_json_lines(t()) :: [String.t()]
  def to_json_lines(%__MODULE__{} = tracer) do
    tracer
    |> steps()
    |> Enum.map(&step_to_json/1)
  end

  @doc "Renders the trace as a single newline-joined JSON string."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = tracer) do
    tracer |> to_json_lines() |> Enum.join("\n")
  end

  defp step_to_json(%TraceStep{} = step) do
    base = %{
      pc: step.pc,
      op: step.op_byte,
      gas: hex(step.gas_remaining),
      gasCost: hex(step.gas_cost),
      memSize: step.memory_size,
      stack: Enum.map(Enum.reverse(step.stack), &hex/1),
      depth: step.depth + 1,
      refund: step.refund,
      opName: Atom.to_string(step.op)
    }

    with_error =
      case step.error do
        nil -> base
        err -> Map.put(base, :error, Atom.to_string(err))
      end

    Jason.encode!(with_error)
  end

  defp hex(n) when is_integer(n), do: ("0x" <> Integer.to_string(n, 16)) |> String.downcase()
end
