defmodule EEVM.Interpreter.Memory do
  @moduledoc """
  Byte-addressable, zero-extended linear memory.

  Backed by a sparse map of written bytes; size is rounded up to a 32-byte
  word and grows monotonically. Reads beyond `size` return zero. Quadratic
  expansion gas is charged separately by `EEVM.Gas.Memory`.
  """

  @type t :: %__MODULE__{
          data: %{non_neg_integer() => byte()},
          size: non_neg_integer()
        }

  defstruct data: %{}, size: 0

  @doc "Creates a new empty memory."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Writes a 32-byte big-endian word at `offset` (MSTORE).
  """
  @spec store(t(), non_neg_integer(), non_neg_integer()) :: t()
  def store(memory, offset, value) do
    bytes = <<value::unsigned-big-integer-size(256)>>

    data =
      bytes
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.reduce(memory.data, fn {byte, i}, acc ->
        Map.put(acc, offset + i, byte)
      end)

    new_size = expand_size(memory.size, offset + 32)
    %__MODULE__{data: data, size: new_size}
  end

  @doc """
  Writes the low byte of `value` at `offset` (MSTORE8).
  """
  @spec store_byte(t(), non_neg_integer(), non_neg_integer()) :: t()
  def store_byte(memory, offset, value) do
    byte = Bitwise.band(value, 0xFF)
    data = Map.put(memory.data, offset, byte)
    new_size = expand_size(memory.size, offset + 1)
    %__MODULE__{data: data, size: new_size}
  end

  @doc """
  Reads a 32-byte big-endian word at `offset` (MLOAD). Unwritten bytes are 0.
  """
  @spec load(t(), non_neg_integer()) :: {non_neg_integer(), t()}
  def load(%__MODULE__{} = memory, offset) do
    bytes =
      for i <- offset..(offset + 31) do
        Map.get(memory.data, i, 0)
      end

    <<value::unsigned-big-integer-size(256)>> = :binary.list_to_bin(bytes)

    new_size = expand_size(memory.size, offset + 32)
    {value, %__MODULE__{memory | size: new_size}}
  end

  @doc """
  Returns `length` bytes starting at `offset` as a binary, zero-filling unwritten bytes.
  """
  @spec read_bytes(t(), non_neg_integer(), non_neg_integer()) :: {binary(), t()}
  def read_bytes(%__MODULE__{} = memory, offset, length) when length > 0 do
    bytes =
      for i <- offset..(offset + length - 1) do
        Map.get(memory.data, i, 0)
      end

    new_size = expand_size(memory.size, offset + length)
    {:binary.list_to_bin(bytes), %__MODULE__{memory | size: new_size}}
  end

  def read_bytes(memory, _offset, 0), do: {<<>>, memory}

  @doc """
  Copies `length` bytes from `src` to `dst` (MCOPY, EIP-5656).

  Reads the source range fully before writing to handle overlapping regions
  correctly (memmove semantics).
  """
  @spec copy(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def copy(memory, _dst, _src, 0), do: memory

  def copy(%__MODULE__{} = memory, dst, src, length) do
    {bytes, memory_after_read} = read_bytes(memory, src, length)

    bytes
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.reduce(memory_after_read, fn {byte, i}, acc ->
      store_byte(acc, dst + i, byte)
    end)
  end

  @doc "Returns the current memory size in bytes (always a multiple of 32)."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  defp expand_size(current, needed) when needed > current do
    div(needed + 31, 32) * 32
  end

  defp expand_size(current, _needed), do: current
end
