defmodule EEVM.Context.Block do
  @moduledoc """
  Block-level context exposed to opcodes: NUMBER, TIMESTAMP, COINBASE,
  GASLIMIT, PREVRANDAO (post-Merge; was DIFFICULTY pre-Merge), BASEFEE
  (EIP-1559), BLOBBASEFEE (EIP-7516), CHAINID, BLOCKHASH (last 256
  ancestors), and `parent_beacon_block_root` (EIP-4788, accessed via the
  beacon-roots contract — no dedicated opcode).
  """

  @type t :: %__MODULE__{
          number: non_neg_integer(),
          timestamp: non_neg_integer(),
          coinbase: non_neg_integer(),
          gaslimit: non_neg_integer(),
          prevrandao: non_neg_integer(),
          basefee: non_neg_integer(),
          blob_base_fee: non_neg_integer(),
          chain_id: non_neg_integer(),
          hashes: %{non_neg_integer() => non_neg_integer()},
          parent_beacon_block_root: non_neg_integer()
        }

  defstruct number: 0,
            timestamp: 0,
            coinbase: 0,
            gaslimit: 0,
            prevrandao: 0,
            basefee: 0,
            blob_base_fee: 0,
            chain_id: 1,
            hashes: %{},
            parent_beacon_block_root: 0

  @doc "Creates a new block context with default values."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a new block context with the given overrides.

  ## Example

      iex> block = EEVM.Context.Block.new(number: 18_000_000, chain_id: 1)
      iex> block.number
      18000000
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end

  @doc """
  BLOCKHASH lookup. Returns 0 outside the last 256 ancestors or for the
  current / a future block.
  """
  @spec hash(t(), non_neg_integer()) :: non_neg_integer()
  def hash(%__MODULE__{hashes: hashes, number: current}, block_number) do
    if block_number < current and block_number >= max(0, current - 256) do
      Map.get(hashes, block_number, 0)
    else
      0
    end
  end
end
