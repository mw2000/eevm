defmodule EEVM.Receipt do
  @moduledoc """
  Transaction receipt — the post-execution summary that gets folded into the
  block's receipts trie.

  ## EVM Concepts

  After a transaction is executed, the chain commits a receipt that captures
  just enough information for clients to verify what happened without re-running
  the transaction. Per the Yellow Paper §4.3.1 a receipt has four fields:

  - `status`               — `1` for a successful transaction, `0` for a
                             reverted/exceptional one. (Pre-Byzantium this slot
                             held a state root; we only support the post-EIP-658
                             status form.)
  - `cumulative_gas_used`  — total gas used in the block *up to and including*
                             this transaction. The trie key is the tx index, so
                             this lets a verifier reconstruct each tx's gas use.
  - `logs_bloom`           — 256-byte bloom filter over every log's address and
                             topics (data is not included). Light clients use
                             this to skip blocks that can't contain events of
                             interest.
  - `logs`                 — the ordered list of LOG-opcode entries the
                             transaction emitted.

  ### Wire encoding (EIP-2718)

  - **Legacy** (type-0) receipts encode as a plain RLP list:
    `RLP([status, cumulative_gas_used, logs_bloom, logs])`.
  - **Typed** receipts (EIP-2930 / 1559 / 4844) prepend a single type byte to
    the same RLP list, e.g. `<<0x02>> <> RLP([...])` for EIP-1559.

  Each log encodes as `[address, [topic, ...], data]`, with the address as a
  20-byte big-endian binary and each topic as a 32-byte big-endian binary.

  ## Elixir Learning Notes

  - `defstruct` builds an immutable record; `new/1` lets callers override any
    subset of fields without re-stating defaults.
  - `:logs_bloom` is *derived* from `:logs` whenever logs are supplied through
    `new/1`, so the two can never drift. A caller that wants to inject a
    bloom directly (e.g. when re-hydrating from RLP) can pass `:logs_bloom`
    explicitly and skip `:logs`.
  - `ExRLP.encode/1` accepts a list of binaries / nested lists; integers must
    be encoded as their minimal big-endian representation, with `0` rendered
    as the empty binary `<<>>`. We do that conversion locally so the rest of
    the module sees regular integers.
  """

  alias EEVM.Bloom

  @type status :: 0 | 1

  @type log_entry :: Bloom.log_entry()

  @type tx_type :: :legacy | :eip2930 | :eip1559 | :eip4844 | non_neg_integer()

  @type t :: %__MODULE__{
          status: status(),
          cumulative_gas_used: non_neg_integer(),
          logs: [log_entry()],
          logs_bloom: Bloom.t()
        }

  defstruct status: 1,
            cumulative_gas_used: 0,
            logs: [],
            logs_bloom: <<0::2048>>

  @type_access_list 0x01
  @type_fee_market 0x02
  @type_blob 0x03

  @doc "A successful, no-op receipt with empty logs and zero cumulative gas."
  @spec new() :: t()
  def new, do: %__MODULE__{logs_bloom: Bloom.empty()}

  @doc """
  Build a receipt, filling in unspecified fields from the defaults.

  When `:logs` is supplied (and `:logs_bloom` is not), the bloom filter is
  derived from the logs so the two stay in sync.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    base = %__MODULE__{logs_bloom: Bloom.empty()}

    {logs_provided?, logs} =
      case Keyword.fetch(opts, :logs) do
        {:ok, value} -> {true, value}
        :error -> {false, base.logs}
      end

    bloom =
      case Keyword.fetch(opts, :logs_bloom) do
        {:ok, value} -> value
        :error -> if logs_provided?, do: Bloom.from_logs(logs), else: base.logs_bloom
      end

    %__MODULE__{
      status: Keyword.get(opts, :status, base.status),
      cumulative_gas_used: Keyword.get(opts, :cumulative_gas_used, base.cumulative_gas_used),
      logs: logs,
      logs_bloom: bloom
    }
  end

  @doc """
  Encode a receipt to its wire (RLP) form.

  Pass `tx_type:` to produce a typed (EIP-2718) receipt. The accepted values
  are `:legacy` (default), `:eip2930`, `:eip1559`, `:eip4844`, or the raw
  integer type byte.
  """
  @spec encode(t(), keyword()) :: binary()
  def encode(%__MODULE__{} = receipt, opts \\ []) do
    payload = ExRLP.encode(rlp_fields(receipt))

    case type_byte(Keyword.get(opts, :tx_type, :legacy)) do
      nil -> payload
      type_byte -> <<type_byte>> <> payload
    end
  end

  defp rlp_fields(%__MODULE__{} = receipt) do
    [
      encode_integer(receipt.status),
      encode_integer(receipt.cumulative_gas_used),
      receipt.logs_bloom,
      Enum.map(receipt.logs, &encode_log/1)
    ]
  end

  defp encode_log(%{address: address, topics: topics, data: data})
       when is_integer(address) and is_list(topics) and is_binary(data) do
    [
      <<address::unsigned-big-160>>,
      Enum.map(topics, fn topic -> <<topic::unsigned-big-256>> end),
      data
    ]
  end

  defp encode_integer(0), do: <<>>

  defp encode_integer(value) when is_integer(value) and value > 0,
    do: :binary.encode_unsigned(value)

  defp type_byte(:legacy), do: nil
  defp type_byte(:eip2930), do: @type_access_list
  defp type_byte(:eip1559), do: @type_fee_market
  defp type_byte(:eip4844), do: @type_blob
  defp type_byte(byte) when is_integer(byte) and byte >= 0 and byte <= 0x7F, do: byte
end
