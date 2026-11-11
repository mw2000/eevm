defmodule EEVM.MPT.Trie do
  @moduledoc """
  Ethereum Merkle Patricia Trie (Yellow Paper, Appendix D), as a persistent
  value that caches each node's hash.

  The trie is path-compressed (nibble keys, hex-prefix compact encoding for
  leaf and extension paths) and content-addressed: each node is RLP-encoded,
  and a parent refers to a child by its RLP when that is shorter than 32
  bytes and by `keccak256(RLP(child))` otherwise.

  `put/3` and `delete/2` rebuild only the nodes on the key's path and mark
  them unhashed; `hash/1` hashes exactly those and returns the trie with the
  hashes filled in. Updating `k` keys of a hashed trie with `n` keys
  therefore costs about `k · log₁₆ n` Keccak-256 calls instead of a rebuild.

      iex> alias EEVM.MPT.Trie
      iex> trie = Trie.new() |> Trie.put("doe", "reindeer") |> Trie.put("dog", "puppy")
      iex> {root, trie} = trie |> Trie.put("dogglesworth", "cat") |> Trie.hash()
      iex> Base.encode16(root, case: :lower)
      "8aad789dff2f538bca5d8ea56e8abe10f4c7ba3a5dea95fea4cd6e7c3a1168d3"
      iex> {^root, _trie} = trie |> Trie.put("do", "verb") |> Trie.delete("do") |> Trie.hash()
  """

  alias EEVM.Crypto.Keccak

  @typedoc "Raw trie key bytes and value bytes (`nil` deletes the key)."
  @type entry :: {binary(), binary() | nil}

  # A child reference: the child's RLP when shorter than 32 bytes, else its
  # hash; nil until `hash/1` computes it.
  @typep ref :: {:raw, binary()} | <<_::256>> | nil

  # Paths are bitstrings of 4-bit nibbles. The ref comes second so comparing
  # a rebuilt node (ref nil) with a hashed one stops early.
  @typep trie_node ::
           {:leaf, ref(), bitstring(), binary()}
           | {:extension, ref(), bitstring(), trie_node()}
           | {:branch, ref(), tuple(), binary() | nil}

  @typedoc "A trie: `nil` when empty."
  @opaque t :: trie_node() | nil

  @empty_trie_root <<0x56E81F171BCC55A6FF8345E692C0F86E5B48E01B996CADC001622FB5E363B421::256>>
  @empty_children List.to_tuple(List.duplicate(nil, 16))

  @doc "Returns the empty trie."
  @spec new() :: t()
  def new, do: nil

  @doc "Returns whether `trie` has no keys."
  @spec empty?(t()) :: boolean()
  def empty?(trie), do: trie == nil

  @doc """
  Computes the root hash of a non-secure trie built from `{key, value}`
  pairs, applied in order: a later value for a key replaces an earlier one,
  and `nil` deletes the key.
  """
  @spec root_hash([entry()]) :: binary()
  def root_hash(entries) when is_list(entries) do
    entries
    |> Enum.reduce(new(), fn
      {key, nil}, trie when is_binary(key) ->
        delete(trie, key)

      {key, value}, trie when is_binary(key) and is_binary(value) ->
        put(trie, key, value)

      bad_entry, _trie ->
        raise ArgumentError,
              "invalid trie entry #{inspect(bad_entry)} (expected {binary_key, binary_value | nil})"
    end)
    |> hash()
    |> elem(0)
  end

  @doc "Like `root_hash/1`, but each key is hashed with Keccak-256 first (a secure trie)."
  @spec secure_root_hash([entry()]) :: binary()
  def secure_root_hash(entries) when is_list(entries),
    do: entries |> Enum.map(fn {key, value} -> {Keccak.hash_256(key), value} end) |> root_hash()

  @doc "Sets `key` to `value`. Returns `trie` itself when `key` already holds `value`."
  @spec put(t(), binary(), binary()) :: t()
  def put(trie, key, value) when is_binary(key) and is_binary(value), do: insert(trie, key, value)

  @doc "Removes `key`. Returns `trie` itself when `key` is absent."
  @spec delete(t(), binary()) :: t()
  def delete(trie, key) when is_binary(key), do: remove(trie, key)

  @doc """
  Returns the root hash and the trie with every node's reference computed,
  hashing only nodes changed since the trie was last hashed.
  """
  @spec hash(t()) :: {<<_::256>>, t()}
  def hash(nil), do: {@empty_trie_root, nil}

  def hash(trie) do
    trie = seal(trie)

    case elem(trie, 1) do
      {:raw, rlp} -> {Keccak.hash_256(rlp), trie}
      hash -> {hash, trie}
    end
  end

  # ---------------------------------------------------------------------------
  # Insertion
  # ---------------------------------------------------------------------------

  defp insert(nil, path, value), do: {:leaf, nil, path, value}
  defp insert({:leaf, _ref, path, value} = leaf, path, value), do: leaf
  defp insert({:leaf, _ref, path, _old}, path, value), do: {:leaf, nil, path, value}

  defp insert({:leaf, _ref, leaf_path, leaf_value}, path, value) do
    prefix = common_prefix(leaf_path, path)
    size = bit_size(prefix)
    <<_::bitstring-size(size), leaf_rest::bitstring>> = leaf_path
    <<_::bitstring-size(size), rest::bitstring>> = path

    {:branch, nil, @empty_children, nil}
    |> insert(leaf_rest, leaf_value)
    |> insert(rest, value)
    |> wrap(prefix)
  end

  defp insert({:extension, _ref, ext_path, child} = node, path, value) do
    size = bit_size(ext_path)

    case path do
      <<^ext_path::bitstring-size(size), rest::bitstring>> ->
        case insert(child, rest, value) do
          ^child -> node
          new_child -> {:extension, nil, ext_path, new_child}
        end

      _ ->
        prefix = common_prefix(ext_path, path)
        prefix_size = bit_size(prefix)
        <<_::bitstring-size(prefix_size), nibble::4, ext_rest::bitstring>> = ext_path
        <<_::bitstring-size(prefix_size), rest::bitstring>> = path
        below = if ext_rest == <<>>, do: child, else: {:extension, nil, ext_rest, child}

        {:branch, nil, put_elem(@empty_children, nibble, below), nil}
        |> insert(rest, value)
        |> wrap(prefix)
    end
  end

  defp insert({:branch, _ref, _children, value} = branch, <<>>, value), do: branch
  defp insert({:branch, _ref, children, _old}, <<>>, value), do: {:branch, nil, children, value}

  defp insert(
         {:branch, _ref, children, branch_value} = branch,
         <<nibble::4, rest::bitstring>>,
         value
       ) do
    child = elem(children, nibble)

    case insert(child, rest, value) do
      ^child -> branch
      new_child -> {:branch, nil, put_elem(children, nibble, new_child), branch_value}
    end
  end

  defp wrap(node, <<>>), do: node
  defp wrap(node, prefix), do: {:extension, nil, prefix, node}

  defp common_prefix(a, b), do: common_prefix(a, b, <<>>)

  defp common_prefix(<<n::4, a::bitstring>>, <<n::4, b::bitstring>>, acc),
    do: common_prefix(a, b, <<acc::bitstring, n::4>>)

  defp common_prefix(_a, _b, acc), do: acc

  # ---------------------------------------------------------------------------
  # Deletion: rebuild the path, then restore the canonical shape (a branch
  # with one entry left collapses into its neighbour).
  # ---------------------------------------------------------------------------

  defp remove(nil, _path), do: nil
  defp remove({:leaf, _ref, path, _value}, path), do: nil
  defp remove({:leaf, _ref, _other, _value} = leaf, _path), do: leaf

  defp remove({:extension, _ref, ext_path, child} = node, path) do
    size = bit_size(ext_path)

    case path do
      <<^ext_path::bitstring-size(size), rest::bitstring>> ->
        case remove(child, rest) do
          ^child -> node
          new_child -> join(ext_path, new_child)
        end

      _ ->
        node
    end
  end

  defp remove({:branch, _ref, _children, nil} = branch, <<>>), do: branch
  defp remove({:branch, _ref, children, _value}, <<>>), do: collapse(children, nil)

  defp remove({:branch, _ref, children, value} = branch, <<nibble::4, rest::bitstring>>) do
    child = elem(children, nibble)

    case remove(child, rest) do
      ^child -> branch
      new_child -> collapse(put_elem(children, nibble, new_child), value)
    end
  end

  # Prefixes `path` onto `node`.
  defp join(path, {:leaf, _ref, rest, value}),
    do: {:leaf, nil, <<path::bitstring, rest::bitstring>>, value}

  defp join(path, {:extension, _ref, rest, child}),
    do: {:extension, nil, <<path::bitstring, rest::bitstring>>, child}

  defp join(path, {:branch, _ref, _children, _value} = branch),
    do: {:extension, nil, path, branch}

  defp collapse(children, value) do
    case {Enum.reject(0..15, &(elem(children, &1) == nil)), value} do
      {[], value} -> {:leaf, nil, <<>>, value}
      {[nibble], nil} -> join(<<nibble::4>>, elem(children, nibble))
      _two_or_more -> {:branch, nil, children, value}
    end
  end

  # ---------------------------------------------------------------------------
  # Hashing
  # ---------------------------------------------------------------------------

  defp seal(nil), do: nil

  defp seal({:leaf, nil, path, value}),
    do: {:leaf, ref(ExRLP.encode([compact(path, true), value])), path, value}

  defp seal({:extension, nil, path, child}) do
    child = seal(child)
    {:extension, ref(list([ExRLP.encode(compact(path, false)), element(child)])), path, child}
  end

  defp seal({:branch, nil, children, value}) do
    children = for(child <- Tuple.to_list(children), do: seal(child))
    rlp = list([Enum.map(children, &element/1), ExRLP.encode(value || <<>>)])
    {:branch, ref(rlp), List.to_tuple(children), value}
  end

  defp seal(hashed), do: hashed

  defp ref(rlp) when byte_size(rlp) < 32, do: {:raw, rlp}
  defp ref(rlp), do: Keccak.hash_256(rlp)

  # A child as an item of its parent's RLP list: embedded when short, else
  # the RLP string of its hash.
  defp element(nil), do: <<0x80>>

  defp element(node) do
    case elem(node, 1) do
      {:raw, rlp} -> rlp
      hash -> <<0xA0, hash::binary>>
    end
  end

  defp list(items) do
    payload = IO.iodata_to_binary(items)
    size = byte_size(payload)

    if size <= 55 do
      <<0xC0 + size, payload::binary>>
    else
      size_bytes = :binary.encode_unsigned(size)
      <<0xF7 + byte_size(size_bytes), size_bytes::binary, payload::binary>>
    end
  end

  # Hex-prefix encoding (Yellow Paper, Appendix C): a flag nibble for leaf
  # vs. extension and odd vs. even length, padded to whole bytes.
  defp compact(path, leaf?) do
    flag = if leaf?, do: 2, else: 0

    case rem(bit_size(path), 8) do
      0 -> <<flag::4, 0::4, path::bitstring>>
      4 -> <<flag + 1::4, path::bitstring>>
    end
  end
end
