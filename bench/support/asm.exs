defmodule EEVM.Bench.Asm do
  @moduledoc """
  Minimal EVM assembler for the benchmark programs.

  A program is a list of:

  - opcode mnemonics as lowercase atoms (`:add`, `:mstore`, `:jumpi`, ...), looked up
    in `EEVM.Interpreter.Instructions.Registry`;
  - non-negative integers, emitted as the smallest PUSH that holds them;
  - `{:label, name}`, emitted as a JUMPDEST;
  - `{:ref, name}`, emitted as `PUSH2 <offset of label name>`.
  """

  alias EEVM.Interpreter.Instructions.Registry

  @opcodes (for byte <- 0..255, {:ok, %{name: name}} <- [Registry.info(byte)], into: %{} do
              {name |> String.downcase() |> String.to_atom(), byte}
            end)

  @spec assemble([atom() | non_neg_integer() | {:label | :ref, atom()}]) :: binary()
  def assemble(program) do
    {chunks, labels, _offset} =
      Enum.reduce(program, {[], %{}, 0}, fn item, {chunks, labels, offset} ->
        chunk = encode(item)

        labels =
          with {:label, name} <- item, do: Map.put(labels, name, offset), else: (_ -> labels)

        {[chunk | chunks], labels, offset + chunk_size(chunk)}
      end)

    chunks
    |> Enum.reverse()
    |> Enum.map(fn
      {:ref, name} -> <<0x61, Map.fetch!(labels, name)::16>>
      bytes -> bytes
    end)
    |> IO.iodata_to_binary()
  end

  defp encode({:label, _name}), do: <<0x5B>>
  defp encode({:ref, _name} = ref), do: ref
  defp encode(op) when is_atom(op), do: <<Map.fetch!(@opcodes, op)>>

  defp encode(value) when is_integer(value) and value >= 0 do
    bytes = :binary.encode_unsigned(value)
    <<0x5F + byte_size(bytes), bytes::binary>>
  end

  defp chunk_size({:ref, _name}), do: 3
  defp chunk_size(bytes), do: byte_size(bytes)
end
