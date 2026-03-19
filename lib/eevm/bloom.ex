defmodule EEVM.Bloom do
  @moduledoc """
  Ethereum logs bloom filter — 2048-bit probabilistic filter for log indexing.

  ## EVM Concepts

  Transaction receipts include a 256-byte (2048-bit) bloom filter that summarizes
  all logs emitted during execution. Light clients use bloom filters to quickly
  skip blocks/transactions that definitely don't contain events of interest.

  Each log's address and each indexed topic are added to the bloom using 3 hash
  probes derived from Keccak-256. The algorithm is defined in Yellow Paper §4.3.1.

  ## Elixir Learning Notes

  - A bloom filter is represented as a fixed-size binary (`<<_::2048>>`).
  - Bit-twiddling uses `Bitwise` operators (`band`, `bor`, `bsl`) on integers.
  - We update a single byte inside a binary with pattern matching slices.
  """

  import Bitwise

  @type log_entry :: %{address: non_neg_integer(), data: binary(), topics: [non_neg_integer()]}
  @type t :: <<_::2048>>

  @empty_bloom <<0::2048>>

  @doc "Returns an empty (all-zero) 256-byte bloom filter."
  @spec empty() :: t()
  def empty, do: @empty_bloom

  @doc """
  Add an item (raw bytes) to the bloom filter.

  The item should be a binary — 20 bytes for an address, 32 bytes for a topic.
  """
  @spec add(t(), binary()) :: t()
  def add(bloom, item) when is_binary(bloom) and byte_size(bloom) == 256 and is_binary(item) do
    <<b0, b1, b2, b3, b4, b5, _::binary>> = ExKeccak.hash_256(item)

    bloom
    |> set_bit(bit_position(b0, b1))
    |> set_bit(bit_position(b2, b3))
    |> set_bit(bit_position(b4, b5))
  end

  @doc """
  Compute the bloom filter for a list of logs.

  Each log's address and topics are added. The `data` field is NOT included.
  """
  @spec from_logs([log_entry()]) :: t()
  def from_logs(logs) do
    Enum.reduce(logs, empty(), fn %{address: address, topics: topics}, bloom ->
      address_bytes = <<address::unsigned-big-160>>

      bloom
      |> add(address_bytes)
      |> add_topics(topics)
    end)
  end

  @doc "Check if a bloom filter might contain an item (false positives possible)."
  @spec contains?(t(), binary()) :: boolean()
  def contains?(bloom, item)
      when is_binary(bloom) and byte_size(bloom) == 256 and is_binary(item) do
    <<b0, b1, b2, b3, b4, b5, _::binary>> = ExKeccak.hash_256(item)

    bit_set?(bloom, bit_position(b0, b1)) and
      bit_set?(bloom, bit_position(b2, b3)) and
      bit_set?(bloom, bit_position(b4, b5))
  end

  @doc "Bitwise OR of two bloom filters."
  @spec merge(t(), t()) :: t()
  def merge(left, right)
      when is_binary(left) and byte_size(left) == 256 and is_binary(right) and
             byte_size(right) == 256 do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.map(fn {a, b} -> bor(a, b) end)
    |> :binary.list_to_bin()
  end

  defp add_topics(bloom, topics) do
    Enum.reduce(topics, bloom, fn topic, acc ->
      topic_bytes = <<topic::unsigned-big-256>>
      add(acc, topic_bytes)
    end)
  end

  defp bit_position(hi, lo), do: band(hi * 256 + lo, 0x07FF)

  defp set_bit(bloom, bit_pos) do
    bit_index = 0x07FF - bit_pos
    byte_index = div(bit_index, 8)
    bit_value = bsl(1, 7 - rem(bit_index, 8))

    <<pre::binary-size(byte_index), byte, post::binary>> = bloom
    <<pre::binary, bor(byte, bit_value), post::binary>>
  end

  defp bit_set?(bloom, bit_pos) do
    bit_index = 0x07FF - bit_pos
    byte_index = div(bit_index, 8)
    bit_value = bsl(1, 7 - rem(bit_index, 8))

    <<_::binary-size(byte_index), byte, _::binary>> = bloom
    band(byte, bit_value) == bit_value
  end
end
