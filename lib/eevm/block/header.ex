defmodule EEVM.Block.Header do
  @moduledoc """
  Ethereum block header — the consensus-critical metadata for a block. A pure
  data carrier; validation lives in `EEVM.Block.Processor`.

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
  | `gas_used` | Total gas the block's transactions consumed, as declared by the producer |
  | `extra_data` | Arbitrary producer bytes (at most 32 bytes on mainnet) |
  | `difficulty` | Proof-of-work difficulty (always zero post-Merge) |
  | `hash` | Keccak hash of this header, as supplied by the caller (not computed here) |
  | `nonce` | 8-byte proof-of-work nonce (all zero post-Merge) |
  | `ommers_hash` | Keccak hash of the RLP ommers list (the empty-list hash post-Merge) |
  | `blob_gas_used` | EIP-4844 blob gas consumed by the block; `nil` before Cancun |
  | `excess_blob_gas` | EIP-4844 running excess blob gas; `nil` before Cancun |
  """

  # keccak256(rlp([]))
  @empty_ommers_hash Base.decode16!(
                       "1DCC4DE8DEC75D7AAB85B567B6CCD41AD312451B948A7413F0A142FD40D49347"
                     )

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
          logs_bloom: binary(),
          gas_used: non_neg_integer(),
          extra_data: binary(),
          difficulty: non_neg_integer(),
          hash: binary(),
          nonce: binary(),
          ommers_hash: binary(),
          blob_gas_used: non_neg_integer() | nil,
          excess_blob_gas: non_neg_integer() | nil
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
            logs_bloom: <<0::2048>>,
            gas_used: 0,
            extra_data: <<>>,
            difficulty: 0,
            hash: <<0::256>>,
            nonce: <<0::64>>,
            ommers_hash: @empty_ommers_hash,
            blob_gas_used: nil,
            excess_blob_gas: nil

  @doc """
  Returns the ommers hash of a block with no ommers, `keccak256(rlp([]))`,
  which every post-Merge header carries.
  """
  @spec empty_ommers_hash() :: binary()
  def empty_ommers_hash, do: @empty_ommers_hash

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
