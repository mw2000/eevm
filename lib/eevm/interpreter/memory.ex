defmodule EEVM.Interpreter.Memory do
  @moduledoc """
  EVM memory — a byte-addressable, dynamically expanding linear memory.

  Memory expands in 32-byte words. Reads or writes beyond the current size
  expand it, and new bytes read as zero. Gas cost increases quadratically with
  memory size (see `EEVM.Gas.Memory`).

  The contents are stored as 4 KiB binary chunks in a map keyed by chunk index.
  Chunks that were never written are absent and read as zeros, so expansion
  only bumps `size`. A write rebuilds just the chunks it touches, and reads
  slice whole ranges out of the chunks. In `bench/` this beat both a map of
  single bytes (the previous layout) and one flat binary, which must copy the
  whole buffer on every write and falls far behind once memory grows past a
  few KiB.
  """

  @chunk_size 4096
  @zero_chunk <<0::size(@chunk_size * 8)>>

  @type t :: %__MODULE__{data: %{non_neg_integer() => binary()}, size: non_neg_integer()}

  defstruct data: %{}, size: 0

  @doc "Creates a new empty memory."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Stores a 256-bit (32-byte) word at the given byte offset, big-endian.

  This is the MSTORE operation.
  """
  @spec store(t(), non_neg_integer(), non_neg_integer()) :: t()
  def store(memory, offset, value), do: write(memory, offset, <<value::unsigned-big-256>>)

  @doc """
  Stores the low byte of `value` at the given offset.

  This is the MSTORE8 operation.
  """
  @spec store_byte(t(), non_neg_integer(), non_neg_integer()) :: t()
  def store_byte(memory, offset, value), do: write(memory, offset, <<value::8>>)

  @doc """
  Loads a 256-bit (32-byte) word from the given byte offset.

  This is the MLOAD operation. Unwritten bytes read as zero.
  """
  @spec load(t(), non_neg_integer()) :: {non_neg_integer(), t()}
  def load(memory, offset) do
    {<<value::unsigned-big-256>>, memory} = read_bytes(memory, offset, 32)
    {value, memory}
  end

  @doc """
  Reads a range of bytes from memory as a binary, expanding memory to cover it.

  Used by RETURN, REVERT, LOG, KECCAK256, CREATE, and the CALL family.
  """
  @spec read_bytes(t(), non_neg_integer(), non_neg_integer()) :: {binary(), t()}
  def read_bytes(memory, _offset, 0), do: {<<>>, memory}

  def read_bytes(memory, offset, length) do
    memory = expand(memory, offset + length)
    {IO.iodata_to_binary(read_chunks(memory.data, offset, length)), memory}
  end

  @doc """
  Writes `length` bytes of `source`, starting at `source_offset`, to memory at
  `offset`. Bytes past the end of `source` are written as zero.

  These are the semantics of CALLDATACOPY, CODECOPY, EXTCODECOPY, and
  RETURNDATACOPY.
  """
  @spec write_slice(t(), non_neg_integer(), binary(), non_neg_integer(), non_neg_integer()) ::
          t()
  def write_slice(memory, _offset, _source, _source_offset, 0), do: memory

  def write_slice(memory, offset, source, source_offset, length) do
    available = min(length, max(byte_size(source) - source_offset, 0))
    slice = if available > 0, do: binary_part(source, source_offset, available), else: <<>>
    write(memory, offset, <<slice::binary, 0::size((length - available) * 8)>>)
  end

  @doc """
  Copies a call's `output` into the caller's output area, `size` bytes at `offset`.

  Only `min(size, byte_size(output))` bytes are written; the rest of the area keeps
  its contents, though memory still expands over all of it, which the CALL already
  paid for (execution-specs `generic_call`, `actual_output_size`).
  """
  @spec write_output(t(), non_neg_integer(), non_neg_integer(), binary()) :: t()
  def write_output(memory, _offset, 0, _output), do: memory

  def write_output(memory, offset, size, output) do
    memory
    |> expand(offset + size)
    |> write(offset, binary_part(output, 0, min(size, byte_size(output))))
  end

  @doc """
  Copies `length` bytes from `src` to `dst` within memory (memmove semantics).

  This is the MCOPY operation (EIP-5656). Overlapping regions are handled
  correctly because the source is read before anything is written.
  """
  @spec copy(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def copy(memory, _dst, _src, 0), do: memory

  def copy(memory, dst, src, length) do
    {bytes, memory} = read_bytes(memory, src, length)
    write(memory, dst, bytes)
  end

  @doc "Returns the current memory size in bytes (always a multiple of 32)."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  defp write(memory, offset, bytes) do
    memory = expand(memory, offset + byte_size(bytes))
    %{memory | data: write_chunks(memory.data, offset, bytes)}
  end

  # Splices `bytes` into the chunk holding `offset`, then continues with the
  # rest in the next chunk.
  defp write_chunks(data, _offset, <<>>), do: data

  defp write_chunks(data, offset, bytes) do
    {index, within, n} = chunk_span(offset, byte_size(bytes))
    <<head::binary-size(n), rest::binary>> = bytes
    <<before::binary-size(within), _::binary-size(n), after_::binary>> = chunk(data, index)
    data = Map.put(data, index, <<before::binary, head::binary, after_::binary>>)
    write_chunks(data, offset + n, rest)
  end

  defp read_chunks(_data, _offset, 0), do: []

  defp read_chunks(data, offset, length) do
    {index, within, n} = chunk_span(offset, length)
    [binary_part(chunk(data, index), within, n) | read_chunks(data, offset + n, length - n)]
  end

  # The chunk index for `offset`, the position within that chunk, and how many
  # of `length` bytes fit before the chunk ends.
  defp chunk_span(offset, length) do
    within = rem(offset, @chunk_size)
    {div(offset, @chunk_size), within, min(length, @chunk_size - within)}
  end

  defp chunk(data, index), do: Map.get(data, index, @zero_chunk)

  # Grows memory to cover `needed` bytes, rounded up to a whole 32-byte word.
  defp expand(%__MODULE__{size: size} = memory, needed) when needed > size do
    %{memory | size: div(needed + 31, 32) * 32}
  end

  defp expand(memory, _needed), do: memory
end
