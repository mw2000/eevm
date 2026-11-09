defmodule EEVM.MemoryTest do
  use ExUnit.Case, async: true

  alias EEVM.Interpreter.Memory

  describe "Memory" do
    test "store and load word" do
      mem = Memory.new()
      mem = Memory.store(mem, 0, 0xFF)

      {value, _mem} = Memory.load(mem, 0)
      assert value == 0xFF
    end

    test "store byte" do
      mem = Memory.new()
      mem = Memory.store_byte(mem, 0, 0xAB)
      mem = Memory.store_byte(mem, 1, 0xCD)

      {value, _mem} = Memory.load(mem, 0)
      # First two bytes are 0xAB, 0xCD, rest are zeros
      assert value == 0xABCD000000000000000000000000000000000000000000000000000000000000
    end

    test "memory expands in 32-byte chunks" do
      mem = Memory.new()
      assert Memory.size(mem) == 0

      mem = Memory.store_byte(mem, 0, 1)
      assert Memory.size(mem) == 32

      mem = Memory.store_byte(mem, 33, 1)
      assert Memory.size(mem) == 64
    end

    test "uninitialized memory reads as zero" do
      mem = Memory.new()
      {value, _mem} = Memory.load(mem, 0)
      assert value == 0
    end
  end
end

defmodule EEVM.MemoryReferenceTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias EEVM.Interpreter.Memory

  # Compares Memory against a flat-binary model over random operation sequences.
  # Offsets cluster around multiples of 4096 so writes, reads, and MCOPYs cross the
  # chunk boundaries of the chunked layout, and run past the current size.

  test "random sequences of every Memory write and read match a flat binary" do
    :rand.seed(:exsss, {7, 11, 13})

    for _sequence <- 1..200 do
      Enum.reduce(1..40, {Memory.new(), <<>>}, fn _step, {memory, model} ->
        {memory, model, observed, expected} = step(random_op(), memory, model)
        assert observed == expected
        assert Memory.size(memory) == byte_size(model)
        {memory, model}
      end)
    end
  end

  defp random_op do
    case :rand.uniform(7) do
      1 ->
        {:store, offset(), :rand.uniform(1 <<< 256) - 1}

      2 ->
        {:store_byte, offset(), :rand.uniform(512)}

      3 ->
        {:load, offset()}

      4 ->
        {:read_bytes, offset(), length()}

      5 ->
        {:write_slice, offset(), :rand.bytes(:rand.uniform(64)), :rand.uniform(80) - 1, length()}

      6 ->
        {:copy, offset(), offset(), length()}

      7 ->
        {:write_output, offset(), :rand.bytes(:rand.uniform(64) - 1), length()}
    end
  end

  defp offset, do: max(4096 * (:rand.uniform(3) - 1) + :rand.uniform(80) - 40, 0)
  defp length, do: Enum.random([0, 1, 31, 32, 33, :rand.uniform(9000)])

  defp step({:store, offset, value}, memory, model),
    do: {Memory.store(memory, offset, value), put(model, offset, <<value::256>>), nil, nil}

  defp step({:store_byte, offset, value}, memory, model),
    do: {Memory.store_byte(memory, offset, value), put(model, offset, <<value::8>>), nil, nil}

  defp step({:load, offset}, memory, model) do
    {value, memory} = Memory.load(memory, offset)
    model = grow(model, offset + 32)
    <<_::binary-size(offset), expected::256, _::binary>> = model
    {memory, model, value, expected}
  end

  defp step({:read_bytes, offset, length}, memory, model) do
    {bytes, memory} = Memory.read_bytes(memory, offset, length)
    model = if length > 0, do: grow(model, offset + length), else: model
    expected = if length > 0, do: binary_part(model, offset, length), else: <<>>
    {memory, model, bytes, expected}
  end

  defp step({:write_slice, offset, source, source_offset, length}, memory, model) do
    padded = source <> <<0::size((source_offset + length) * 8)>>
    bytes = binary_part(padded, source_offset, length)
    model = if length > 0, do: put(model, offset, bytes), else: model
    {Memory.write_slice(memory, offset, source, source_offset, length), model, nil, nil}
  end

  defp step({:write_output, offset, output, size}, memory, model) do
    model =
      if size > 0 do
        model
        |> grow(offset + size)
        |> put(offset, binary_part(output, 0, min(size, byte_size(output))))
      else
        model
      end

    {Memory.write_output(memory, offset, size, output), model, nil, nil}
  end

  defp step({:copy, dst, src, length}, memory, model) do
    model =
      if length > 0 do
        model = grow(model, src + length)
        put(model, dst, binary_part(model, src, length))
      else
        model
      end

    {Memory.copy(memory, dst, src, length), model, nil, nil}
  end

  defp put(model, offset, bytes) do
    model = grow(model, offset + byte_size(bytes))
    <<before::binary-size(offset), _::binary-size(byte_size(bytes)), rest::binary>> = model
    <<before::binary, bytes::binary, rest::binary>>
  end

  defp grow(model, needed) when needed > byte_size(model),
    do: model <> <<0::size((div(needed + 31, 32) * 32 - byte_size(model)) * 8)>>

  defp grow(model, _needed), do: model
end
