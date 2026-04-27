defmodule EEVM.MPT.Trie do
  @moduledoc """
  Merkle Patricia Trie root computation, matching the Yellow Paper / execution
  specs.

  Path-compressed nibble trie with three node kinds (leaf, extension, branch),
  hex-prefix encoded paths, RLP-encoded nodes, and the 32-byte rule for child
  references (inline if `byte_size(rlp(node)) < 32`, else `keccak256(rlp)`).

  Stateless and read-only: `root_hash/1` and `secure_root_hash/1` build a
  trie in memory from `[{key, value}]` and emit the 32-byte root. Compatible
  with geth / revm output for the same input.
  """

  alias EEVM.MPT.HexPrefix

  @typedoc "Nibble values used for trie paths."
  @type nibble :: 0..15

  @typedoc "Raw trie key bytes and value bytes (nil means deletion in sequential updates)."
  @type entry :: {binary(), binary() | nil}

  @type trie_node ::
          nil
          | {:leaf, [nibble()], binary()}
          | {:extension, [nibble()], trie_node()}
          | {:branch, %{optional(nibble()) => trie_node()}, binary() | nil}

  @type node_ref :: {:raw, binary()} | binary()

  @empty_trie_root Base.decode16!(
                     "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
                     case: :lower
                   )

  @doc """
  Computes the MPT root hash from `{key, value}` pairs.

  Keys are inserted as-is (non-secure trie). Entries are applied sequentially;
  if a key appears multiple times, later values overwrite earlier ones. A `nil`
  value deletes the key.
  """
  @spec root_hash([entry()]) :: binary()
  def root_hash(entries) when is_list(entries) do
    entries
    |> build_kv_map()
    |> patricialize(0)
    |> root_from_node()
  end

  @doc """
  Computes the secure-trie MPT root hash.

  Secure tries pre-hash each key with Keccak-256 before insertion.
  """
  @spec secure_root_hash([entry()]) :: binary()
  def secure_root_hash(entries) when is_list(entries) do
    secure_entries =
      Enum.map(entries, fn {key, value} -> {ExKeccak.hash_256(key), value} end)

    root_hash(secure_entries)
  end

  @spec root_from_node(trie_node()) :: binary()
  defp root_from_node(nil), do: @empty_trie_root

  defp root_from_node(node) do
    node
    |> encode_node_rlp()
    |> ExKeccak.hash_256()
  end

  @spec build_kv_map([entry()]) :: %{[nibble()] => binary()}
  defp build_kv_map(entries) do
    Enum.reduce(entries, %{}, fn
      {key, nil}, acc when is_binary(key) ->
        Map.delete(acc, key_to_nibbles(key))

      {key, value}, acc when is_binary(key) and is_binary(value) ->
        Map.put(acc, key_to_nibbles(key), value)

      bad_entry, _acc ->
        raise ArgumentError,
              "invalid trie entry #{inspect(bad_entry)} (expected {binary_key, binary_value | nil})"
    end)
  end

  @spec patricialize(%{[nibble()] => binary()}, non_neg_integer()) :: trie_node()
  defp patricialize(obj, _level) when map_size(obj) == 0, do: nil

  defp patricialize(obj, level) when map_size(obj) == 1 do
    [{key_nibbles, value}] = Map.to_list(obj)
    {:leaf, drop_nibbles(key_nibbles, level), value}
  end

  defp patricialize(obj, level) do
    keys = Map.keys(obj)
    shared = common_prefix_length(keys, level)

    if shared > 0 do
      [{first_key, _}] = Map.to_list(obj) |> Enum.take(1)
      shared_nibbles = take_slice(first_key, level, shared)
      {:extension, shared_nibbles, patricialize(obj, level + shared)}
    else
      build_branch(obj, level)
    end
  end

  @spec build_branch(%{[nibble()] => binary()}, non_neg_integer()) :: trie_node()
  defp build_branch(obj, level) do
    {value_at_prefix, buckets} =
      Enum.reduce(obj, {nil, %{}}, fn {key_nibbles, value}, {exact_value, acc_buckets} ->
        if length(key_nibbles) == level do
          {value, acc_buckets}
        else
          nibble = Enum.at(key_nibbles, level)
          updated_bucket = Map.put(Map.get(acc_buckets, nibble, %{}), key_nibbles, value)
          {exact_value, Map.put(acc_buckets, nibble, updated_bucket)}
        end
      end)

    children =
      Enum.reduce(0..15, %{}, fn nibble, acc ->
        Map.put(acc, nibble, patricialize(Map.get(buckets, nibble, %{}), level + 1))
      end)

    {:branch, children, value_at_prefix}
  end

  @spec encode_node(trie_node()) :: node_ref()
  defp encode_node(node) do
    encoded = encode_node_rlp(node)

    if byte_size(encoded) < 32 do
      {:raw, encoded}
    else
      ExKeccak.hash_256(encoded)
    end
  end

  @spec encode_node_rlp(trie_node()) :: binary()
  defp encode_node_rlp(nil), do: ExRLP.encode(<<>>)

  defp encode_node_rlp({:leaf, path_nibbles, value}) do
    ExRLP.encode([HexPrefix.encode(path_nibbles, true), value])
  end

  defp encode_node_rlp({:extension, shared_nibbles, child}) do
    child_element = child_to_element(child)
    encode_list_raw([HexPrefix.encode(shared_nibbles, false), child_element])
  end

  defp encode_node_rlp({:branch, children, value}) do
    child_elements =
      Enum.map(0..15, fn nibble ->
        child_to_element(Map.get(children, nibble))
      end)

    encode_list_raw(child_elements ++ [value || <<>>])
  end

  @spec child_to_element(trie_node()) :: binary() | {:raw, binary()}
  defp child_to_element(nil), do: <<>>

  defp child_to_element(child) do
    case encode_node(child) do
      {:raw, encoded} -> {:raw, encoded}
      hash -> hash
    end
  end

  @spec encode_list_raw([term() | {:raw, binary()}]) :: binary()
  defp encode_list_raw(elements) do
    payload =
      Enum.reduce(elements, <<>>, fn
        {:raw, encoded}, acc -> acc <> encoded
        term, acc -> acc <> ExRLP.encode(term)
      end)

    encode_list_header(payload)
  end

  @spec encode_list_header(binary()) :: binary()
  defp encode_list_header(payload) do
    length = byte_size(payload)

    if length <= 55 do
      <<0xC0 + length, payload::binary>>
    else
      length_bytes = :binary.encode_unsigned(length)
      <<0xF7 + byte_size(length_bytes), length_bytes::binary, payload::binary>>
    end
  end

  @spec key_to_nibbles(binary()) :: [nibble()]
  defp key_to_nibbles(key), do: key_to_nibbles(key, [])

  defp key_to_nibbles(<<>>, acc), do: Enum.reverse(acc)

  defp key_to_nibbles(<<high::4, low::4, rest::binary>>, acc) do
    key_to_nibbles(rest, [low, high | acc])
  end

  @spec common_prefix_length([[nibble()]], non_neg_integer()) :: non_neg_integer()
  defp common_prefix_length(keys, level), do: common_prefix_length(keys, level, 0)

  defp common_prefix_length(keys, level, acc) do
    index = level + acc

    if Enum.any?(keys, &(length(&1) <= index)) do
      acc
    else
      [first_key | _] = keys
      nibble = Enum.at(first_key, index)

      if Enum.all?(keys, &(Enum.at(&1, index) == nibble)) do
        common_prefix_length(keys, level, acc + 1)
      else
        acc
      end
    end
  end

  @spec drop_nibbles([nibble()], non_neg_integer()) :: [nibble()]
  defp drop_nibbles(nibbles, count), do: Enum.drop(nibbles, count)

  @spec take_slice([nibble()], non_neg_integer(), non_neg_integer()) :: [nibble()]
  defp take_slice(nibbles, start, length), do: Enum.slice(nibbles, start, length)
end
