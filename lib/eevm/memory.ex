defmodule EEVM.Memory do
  @moduledoc """
  EVM memory — a byte-addressable, dynamically expanding linear memory.

  ## EVM Concepts

  - Memory is a word-addressed byte array that expands in 32-byte chunks.
  - Reading/writing beyond current size auto-expands (zero-filled).
  - Gas cost increases quadratically with memory size (not implemented yet).

  ## Elixir Learning Notes

  - We use a `Map` for sparse storage — only written bytes are stored.
    This is more memory-efficient than a huge binary for a learning impl.
  - `Map.get(map, key, default)` returns a default if the key is missing —
    perfect for zero-filled memory semantics.
  - Binaries (`<<>>`) are Elixir's way of handling raw bytes. We use them
    for reading contiguous chunks.
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
  Stores a 256-bit (32-byte) word at the given byte offset.

  This is the MSTORE operation. The value is stored big-endian,
  which is the EVM's byte ordering convention.
  """
  @spec store(t(), non_neg_integer(), non_neg_integer()) :: t()
  def store(memory, offset, value) do
    # Convert the 256-bit integer to a 32-byte big-endian binary
    bytes = <<value::unsigned-big-integer-size(256)>>

    # Write each byte individually into our map
    data =
      bytes
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.reduce(memory.data, fn {byte, i}, acc ->
        Map.put(acc, offset + i, byte)
      end)

    # Expand memory size if needed (rounds up to 32-byte words)
    new_size = expand_size(memory.size, offset + 32)
    %__MODULE__{data: data, size: new_size}
  end

  @doc """
  Stores a single byte at the given offset.

  This is the MSTORE8 operation.
  """
  @spec store_byte(t(), non_neg_integer(), non_neg_integer()) :: t()
  def store_byte(memory, offset, value) do
    byte = Bitwise.band(value, 0xFF)
    data = Map.put(memory.data, offset, byte)
    new_size = expand_size(memory.size, offset + 1)
    %__MODULE__{data: data, size: new_size}
  end

  @doc """
  Loads a 256-bit (32-byte) word from the given byte offset.

  This is the MLOAD operation. Unwritten bytes read as zero.
  """
  @spec load(t(), non_neg_integer()) :: {non_neg_integer(), t()}
  def load(%__MODULE__{} = memory, offset) do
    # Read 32 bytes, defaulting unset bytes to 0
    bytes =
      for i <- offset..(offset + 31) do
        Map.get(memory.data, i, 0)
      end

    # Convert the 32 bytes back to a 256-bit integer (big-endian)
    <<value::unsigned-big-integer-size(256)>> = :binary.list_to_bin(bytes)

    new_size = expand_size(memory.size, offset + 32)
    {value, %__MODULE__{memory | size: new_size}}
  end

  @doc """
  Reads a range of bytes from memory as a binary.

  Used by RETURN, REVERT, and LOG operations.
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
  Copies `length` bytes from `src` to `dst` within memory (memmove semantics).

  This is the MCOPY operation (EIP-5656). Handles overlapping regions correctly
  by reading all source bytes before writing — similar to C's `memmove`.
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

  # --- Private Helpers ---

  # Expands memory size to cover `needed` bytes, rounding up to 32-byte words.
  # `div/2` and `rem/2` are kernel functions for integer division and remainder.
  defp expand_size(current, needed) when needed > current do
    words = div(needed + 31, 32)
    words * 32
  end

  defp expand_size(current, _needed), do: current
end
