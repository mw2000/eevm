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
    | `gas_cost` | The opcode's gas cost. For now this is the static cost only: memory expansion, cold access, SSTORE, and other dynamic costs are missing (#213). INVALID reports all remaining gas |
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

  @type t :: %__MODULE__{steps: [TraceStep.t()]}

  defstruct steps: []

  @doc "Returns an empty tracer. `tracer: true` is shorthand for `tracer: EEVM.Tracer.new()`."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc false
  # Called by the interpreter for each step.
  @spec record(t(), TraceStep.t()) :: t()
  def record(%__MODULE__{steps: steps} = tracer, %TraceStep{} = step) do
    %{tracer | steps: [step | steps]}
  end

  @doc false
  # Called by the interpreter: marks the most recently recorded step with an error reason.
  @spec set_last_error(t(), atom()) :: t()
  def set_last_error(%__MODULE__{steps: []} = tracer, _reason), do: tracer

  def set_last_error(%__MODULE__{steps: [last | rest]} = tracer, reason) do
    %{tracer | steps: [%{last | error: reason} | rest]}
  end

  @doc "Returns the recorded steps in execution order."
  @spec steps(t()) :: [TraceStep.t()]
  def steps(%__MODULE__{steps: steps}), do: Enum.reverse(steps)

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
