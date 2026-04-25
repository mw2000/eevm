defmodule EEVM.Block.Receipt do
  @moduledoc """
  Per-transaction receipt emitted after execution.

  ## EVM Concepts

  A receipt is the execution-layer's summary of what happened when a transaction
  ran. It does not carry the full transaction payload — instead it records the
  post-conditions an observer needs to validate state transitions:

  - `status` — `1` if the top-level call completed, `0` if it reverted. The
    Byzantium hardfork replaced the pre-image `state_root` field with this
    one-byte status code; this module follows that modern layout.
  - `cumulative_gas_used` — total gas consumed in the block up to and including
    this transaction. Per the Yellow Paper, receipts are ordered and the
    `cumulative_gas_used` of the last receipt equals the block's `gas_used`.
  - `logs` — every log entry emitted by this transaction, in emission order.
    Each log is a map matching `EEVM.Block.Bloom.log_entry/0`.
  - `logs_bloom` — the 2048-bit bloom filter over this receipt's logs, i.e.
    `EEVM.Block.Bloom.from_logs(logs)`. We store it pre-computed so block-level
    aggregation is a fast bytewise OR.

  ## Wire encoding (EIP-2718)

  - **Legacy** (type-0) receipts encode as a plain RLP list:
    `RLP([status, cumulative_gas_used, logs_bloom, logs])`.
  - **Typed** receipts (EIP-2930 / 1559 / 4844) prepend a single type byte to
    the same RLP list, e.g. `<<0x02>> <> RLP([...])` for EIP-1559.

  Each log encodes as `[address, [topic, ...], data]`, with the address as a
  20-byte big-endian binary and each topic as a 32-byte big-endian binary.
  """

  alias EEVM.Block.Bloom

  @type log :: Bloom.log_entry()

  @type tx_type :: :legacy | :eip2930 | :eip1559 | :eip4844 | non_neg_integer()

  @type t :: %__MODULE__{
          status: 0 | 1,
          cumulative_gas_used: non_neg_integer(),
          logs: [log()],
          logs_bloom: Bloom.t()
        }

  defstruct status: 1,
            cumulative_gas_used: 0,
            logs: [],
            logs_bloom: <<0::2048>>

  @type_access_list 0x01
  @type_fee_market 0x02
  @type_blob 0x03

  @doc "Returns a successful receipt with no logs and zero cumulative gas."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Returns a receipt with the given overrides.

  If `:logs` is supplied without an explicit `:logs_bloom`, the bloom is
  derived from the logs automatically so callers cannot produce a receipt
  whose bloom is out of sync with its logs.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    base = struct!(__MODULE__, opts)

    cond do
      Keyword.has_key?(opts, :logs_bloom) -> base
      Keyword.has_key?(opts, :logs) -> %{base | logs_bloom: Bloom.from_logs(base.logs)}
      true -> base
    end
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
