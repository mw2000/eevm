defmodule EEVM.Interpreter.Stack do
  @moduledoc """
  EVM stack: LIFO of uint256 values, depth-bounded at 1024.

  Push/pop are O(1) on the head of an Elixir list. Values are masked to 256
  bits on push so callers can pass raw integers without truncating first.
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
  Pushes a uint256 onto the stack. Masks the value to 256 bits.

  Returns `{:error, :stack_overflow}` if the stack is at the 1024-element cap.
  """
  @spec push(t(), non_neg_integer()) :: {:ok, t()} | {:error, :stack_overflow}
  def push(%__MODULE__{size: size}, _value) when size >= @max_depth do
    {:error, :stack_overflow}
  end

  def push(%__MODULE__{elements: elements, size: size}, value) do
    masked = band_256(value)
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

  defp band_256(value) do
    import Bitwise
    band(value, (1 <<< 256) - 1)
  end
end
