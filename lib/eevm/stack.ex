defmodule EEVM.Stack do
  @moduledoc """
  The EVM stack — a LIFO data structure with a max depth of 1024.

  ## Elixir Learning Notes

  - We use a simple list as the underlying data structure. In Elixir, lists are
    linked lists, so prepending (push) is O(1) and popping the head is O(1).
  - The `@max_depth` is a module attribute — Elixir's version of a constant.
  - Pattern matching in function heads (`[top | rest]`) is idiomatic Elixir —
    we destructure data right where we receive it.
  - We return tagged tuples like `{:ok, value}` and `{:error, reason}` which is
    the Elixir convention for fallible operations.
  """

  @max_depth 1024

  @type t :: %__MODULE__{
          elements: [non_neg_integer()],
          size: non_neg_integer()
        }

  defstruct elements: [], size: 0

  @doc "Creates a new empty stack."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Pushes a value onto the stack.

  Returns `{:ok, stack}` or `{:error, :stack_overflow}` if the stack is full.

  EVM values are 256-bit unsigned integers. We enforce this with a bitmask.
  """
  @spec push(t(), non_neg_integer()) :: {:ok, t()} | {:error, :stack_overflow}
  def push(%__MODULE__{size: size}, _value) when size >= @max_depth do
    {:error, :stack_overflow}
  end

  def push(%__MODULE__{elements: elements, size: size}, value) do
    # Mask to 256 bits — all EVM values are uint256
    masked = value |> band_256()
    {:ok, %__MODULE__{elements: [masked | elements], size: size + 1}}
  end

  @doc """
  Pops the top value from the stack.

  Returns `{:ok, value, new_stack}` or `{:error, :stack_underflow}`.
  """
  @spec pop(t()) :: {:ok, non_neg_integer(), t()} | {:error, :stack_underflow}
  def pop(%__MODULE__{elements: []}), do: {:error, :stack_underflow}

  def pop(%__MODULE__{elements: [top | rest], size: size}) do
    {:ok, top, %__MODULE__{elements: rest, size: size - 1}}
  end

  @doc """
  Peeks at the element at the given depth (0 = top of stack).

  Used by DUP and SWAP instructions.
  """
  @spec peek(t(), non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, :stack_underflow}
  def peek(%__MODULE__{elements: elements, size: size}, depth) when depth < size do
    {:ok, Enum.at(elements, depth)}
  end

  def peek(_stack, _depth), do: {:error, :stack_underflow}

  @doc """
  Swaps the top element with the element at the given depth.

  SWAP1 swaps positions 0 and 1, SWAP2 swaps 0 and 2, etc.
  """
  @spec swap(t(), pos_integer()) :: {:ok, t()} | {:error, :stack_underflow}
  def swap(%__MODULE__{size: size}, depth) when depth >= size do
    {:error, :stack_underflow}
  end

  def swap(%__MODULE__{elements: elements, size: size}, depth) do
    top = Enum.at(elements, 0)
    target = Enum.at(elements, depth)

    new_elements =
      elements
      |> List.replace_at(0, target)
      |> List.replace_at(depth, top)

    {:ok, %__MODULE__{elements: new_elements, size: size}}
  end

  @doc "Returns the current stack depth."
  @spec depth(t()) :: non_neg_integer()
  def depth(%__MODULE__{size: size}), do: size

  @doc "Converts the stack to a list (top element first) for inspection."
  @spec to_list(t()) :: [non_neg_integer()]
  def to_list(%__MODULE__{elements: elements}), do: elements

  # --- Private Helpers ---

  # Masks a value to 256 bits. The EVM uses unsigned 256-bit integers.
  # In Elixir, integers are arbitrary precision, so we manually enforce the limit.
  #
  # `Bitwise.band/2` performs a bitwise AND.
  # `(1 <<< 256) - 1` creates a 256-bit mask of all 1s.
  defp band_256(value) do
    import Bitwise
    band(value, (1 <<< 256) - 1)
  end
end
