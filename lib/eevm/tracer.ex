defmodule EEVM.Tracer do
  @moduledoc """
  Opt-in opcode-level execution tracer.

  A tracer is attached to a `MachineState` (via `MachineState.new/2` with
  `tracer: EEVM.Tracer.new()`). When present, the executor records one
  `TraceStep` per opcode with pre-execution PC, stack, memory size, and
  depth plus the actual gas cost charged by that step.

  Output is compatible with the `evm --json` format defined by EIP-3155,
  so traces can be diffed against geth/revm reference runs.

  ## Performance

  When the `tracer` field is `nil` (default), the executor skips all trace
  bookkeeping — no snapshot is taken and the tracer branch is a single
  pattern-match-and-return. Trace capture is opt-in at the call site.
  """

  alias EEVM.Opcodes.Registry

  defmodule TraceStep do
    @moduledoc "A single recorded step: one opcode execution in the trace."

    @type t :: %__MODULE__{
            pc: non_neg_integer(),
            op: atom(),
            op_byte: non_neg_integer(),
            gas_remaining: non_neg_integer(),
            gas_cost: non_neg_integer(),
            stack: [non_neg_integer()],
            memory_size: non_neg_integer(),
            depth: non_neg_integer(),
            refund: non_neg_integer(),
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
          refund: non_neg_integer()
        }

  @type t :: %__MODULE__{steps: [TraceStep.t()]}

  defstruct steps: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec record(t(), TraceStep.t()) :: t()
  def record(%__MODULE__{steps: steps} = tracer, %TraceStep{} = step) do
    %{tracer | steps: [step | steps]}
  end

  @doc "Marks the most recently recorded step with an error reason."
  @spec set_last_error(t(), atom()) :: t()
  def set_last_error(%__MODULE__{steps: []} = tracer, _reason), do: tracer

  def set_last_error(%__MODULE__{steps: [last | rest]} = tracer, reason) do
    %{tracer | steps: [%{last | error: reason} | rest]}
  end

  @doc "Returns the recorded steps in execution order."
  @spec steps(t()) :: [TraceStep.t()]
  def steps(%__MODULE__{steps: steps}), do: Enum.reverse(steps)

  @doc "Returns the opcode name atom for a byte (e.g. `0x01` -> `:ADD`)."
  @spec op_name(non_neg_integer()) :: atom()
  def op_name(opcode) do
    case Registry.info(opcode) do
      {:ok, %{name: name}} -> String.to_atom(name)
      {:error, _} -> :UNKNOWN
    end
  end

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
