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

  The processor fills in `cumulative_gas_used` and `logs_bloom` after each
  transaction; the injected tx executor is only responsible for the raw
  status / gas / logs triple.

  ## Elixir Learning Notes

  - This is a thin struct — no logic. Constructors default to a successful
    receipt with no logs so tests can build interesting cases with just the
    overrides that matter.
  - The `logs` type mirrors `EEVM.Block.Bloom.log_entry/0` exactly to keep the
    two modules compatible without mutual imports.
  """

  alias EEVM.Block.Bloom

  @type log :: Bloom.log_entry()

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
end
