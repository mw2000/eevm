defmodule EEVM.MPT.HexPrefix do
  @moduledoc """
  Hex-prefix (compact) encoding for MPT leaf and extension paths.

  Packs a nibble list plus two flag bits — leaf-vs-extension and
  odd-vs-even-length — into bytes. The first nibble is `2*leaf + odd`:

  - `0x0` extension, even
  - `0x1` extension, odd
  - `0x2` leaf, even
  - `0x3` leaf, odd

  An even-length path is preceded by an extra `0` nibble so the encoding
  always lands on byte boundaries.
  """

  @typedoc "Nibble values used in hex-prefix paths."
  @type nibble :: 0..15

  @doc """
  Encodes a nibble path using Ethereum hex-prefix rules.
  """
  @spec encode([nibble()], boolean()) :: binary()
  def encode(nibbles, is_leaf) when is_list(nibbles) and is_boolean(is_leaf) do
    validate_nibbles!(nibbles)

    flag_base = if(is_leaf, do: 2, else: 0)

    prefixed_nibbles =
      if rem(length(nibbles), 2) == 0 do
        [flag_base, 0 | nibbles]
      else
        [flag_base + 1 | nibbles]
      end

    pack_nibbles(prefixed_nibbles)
  end

  @doc """
  Decodes Ethereum hex-prefix bytes into `{nibbles, is_leaf}`.
  """
  @spec decode(binary()) :: {[nibble()], boolean()}
  def decode(bytes) when is_binary(bytes) do
    case unpack_nibbles(bytes) do
      [] ->
        raise ArgumentError, "hex-prefix bytes cannot be empty"

      [flag | rest] when flag in 0..3 ->
        is_leaf = flag >= 2
        is_odd = rem(flag, 2) == 1

        nibbles =
          if is_odd do
            rest
          else
            case rest do
              [0 | tail] -> tail
              _ -> raise ArgumentError, "invalid even-length hex-prefix encoding"
            end
          end

        validate_nibbles!(nibbles)
        {nibbles, is_leaf}

      _ ->
        raise ArgumentError, "invalid hex-prefix flag nibble"
    end
  end

  @spec pack_nibbles([nibble()]) :: binary()
  defp pack_nibbles(nibbles), do: pack_nibbles(nibbles, <<>>)

  defp pack_nibbles([], acc), do: acc

  defp pack_nibbles([high, low | rest], acc),
    do: pack_nibbles(rest, <<acc::binary, high::4, low::4>>)

  @spec unpack_nibbles(binary()) :: [nibble()]
  defp unpack_nibbles(bytes), do: unpack_nibbles(bytes, [])

  defp unpack_nibbles(<<>>, acc), do: Enum.reverse(acc)

  defp unpack_nibbles(<<high::4, low::4, rest::binary>>, acc) do
    unpack_nibbles(rest, [low, high | acc])
  end

  @spec validate_nibbles!([integer()]) :: :ok
  defp validate_nibbles!(nibbles) do
    Enum.each(nibbles, fn
      nibble when nibble in 0..15 -> :ok
      nibble -> raise ArgumentError, "invalid nibble #{inspect(nibble)} (expected 0..15)"
    end)

    :ok
  end
end
