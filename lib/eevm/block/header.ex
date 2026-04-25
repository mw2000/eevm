defmodule EEVM.Block.Header do
  @moduledoc """
  Ethereum block header — the consensus-critical metadata for a block.

  ## EVM Concepts

  A block header is a thin descriptor of a block. It advertises the pre-state
  parent pointers, the execution parameters (gas limit, base fee, randomness),
  and the post-execution commitments (state / receipts / transactions roots
  plus the aggregated logs bloom).

  The execution client is responsible for checking that the post-execution
  commitments it computes match the ones advertised here. This struct is a
  pure data carrier — validation lives in `EEVM.Block.Processor`.

  ### Fields

  | Field | Description |
  |-------|-------------|
  | `number` | Block number (height on the chain) |
  | `parent_hash` | Keccak hash of the parent header |
  | `timestamp` | Block timestamp in seconds since epoch |
  | `coinbase` | Address of the block producer (fee recipient) |
  | `gas_limit` | Maximum cumulative gas the block may consume |
  | `base_fee_per_gas` | EIP-1559 base fee |
  | `prev_randao` | RANDAO mix inherited from the beacon chain (post-Merge) |
  | `parent_beacon_block_root` | EIP-4788 beacon root pointer from the parent slot |
  | `state_root` | Post-execution world-state MPT root |
  | `receipts_root` | MPT root of `{rlp(index) => rlp(receipt)}` |
  | `transactions_root` | MPT root of `{rlp(index) => rlp(transaction)}` |
  | `logs_bloom` | 256-byte bloom summarising every log in the block |

  ## Elixir Learning Notes

  - This module defines only a struct plus tiny constructors. The field types
    deliberately mirror `EEVM.Context.Block` where they overlap so callers can
    move values between the "what the network says" layer (`Header`) and the
    "what opcodes see" layer (`Context.Block`) without impedance.
  - `new/0` and `new/1` follow the same zero-arg / keyword-override idiom used
    by the rest of the codebase.
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
