defmodule EEVM.Block.Header do
  @moduledoc """
  Block header struct — the consensus-critical metadata advertising both
  parent pointers / execution parameters and the post-execution commitments
  (`state_root`, `receipts_root`, `transactions_root`, `logs_bloom`).

  Pure data carrier; validation lives in `EEVM.Block.Processor`. Field types
  mirror `EEVM.Context.Block` where they overlap.
  """

  @type t :: %__MODULE__{
          number: non_neg_integer(),
          parent_hash: binary(),
          timestamp: non_neg_integer(),
          coinbase: non_neg_integer(),
          gas_limit: non_neg_integer(),
          base_fee_per_gas: non_neg_integer(),
          prev_randao: non_neg_integer(),
          parent_beacon_block_root: non_neg_integer(),
          state_root: binary(),
          receipts_root: binary(),
          transactions_root: binary(),
          logs_bloom: binary()
        }

  defstruct number: 0,
            parent_hash: <<0::256>>,
            timestamp: 0,
            coinbase: 0,
            gas_limit: 0,
            base_fee_per_gas: 0,
            prev_randao: 0,
            parent_beacon_block_root: 0,
            state_root: <<0::256>>,
            receipts_root: <<0::256>>,
            transactions_root: <<0::256>>,
            logs_bloom: <<0::2048>>

  @doc "Returns a zero-initialised header."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Returns a header with the given overrides.

  ## Example

      iex> header = EEVM.Block.Header.new(number: 18_000_000, gas_limit: 30_000_000)
      iex> {header.number, header.gas_limit}
      {18_000_000, 30_000_000}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end
end
