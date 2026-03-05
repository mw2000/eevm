defmodule EEVM.Context.Block do
  @moduledoc """
  Block-level context — information about the block being executed.

  ## EVM Concepts

  The EVM has access to the block it's executing within. Smart contracts
  use this to read timestamps, block numbers, and randomness (PREVRANDAO).

  In revm, this is the `Block` trait — the second of three context layers.

  ### Fields

  | Field | Opcode | Description |
  |-------|--------|-------------|
  | `number` | NUMBER (0x43) | Current block number |
  | `timestamp` | TIMESTAMP (0x42) | Block timestamp (seconds since epoch) |
  | `coinbase` | COINBASE (0x41) | Address of the block producer |
  | `gaslimit` | GASLIMIT (0x45) | Block gas limit |
  | `prevrandao` | PREVRANDAO (0x44) | Previous block's RANDAO mix (post-Merge) |
  | `basefee` | BASEFEE (0x48) | Block base fee from EIP-1559 |
  | `chain_id` | CHAINID (0x46) | Network ID (1=mainnet, 137=Polygon, etc.) |
  | `hashes` | BLOCKHASH (0x40) | Map of recent block numbers to their hashes |

  ### PREVRANDAO

  Before The Merge, opcode 0x44 was DIFFICULTY. Post-Merge, the same opcode
  returns the RANDAO mix from the Beacon Chain — a source of on-chain randomness.

  ## Elixir Learning Notes

  - The `hashes` field is a Map — Elixir maps provide O(log n) lookup.
  - `hash/2` validates that the requested block is within the last 256 blocks,
    matching the EVM spec's constraint.
  - `max/2` is a Kernel function — we use it to avoid negative numbers.
  """

  @type t :: %__MODULE__{
          number: non_neg_integer(),
          timestamp: non_neg_integer(),
          coinbase: non_neg_integer(),
          gaslimit: non_neg_integer(),
          prevrandao: non_neg_integer(),
          basefee: non_neg_integer(),
          chain_id: non_neg_integer(),
          hashes: %{non_neg_integer() => non_neg_integer()}
        }

  defstruct number: 0,
            timestamp: 0,
            coinbase: 0,
            gaslimit: 0,
            prevrandao: 0,
            basefee: 0,
            chain_id: 1,
            hashes: %{}

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
  Returns the block hash for a given block number.

  Returns 0 if the block number is not in the last 256 blocks or is the
  current/future block. This matches the EVM spec — BLOCKHASH can only
  access the most recent 256 ancestors.
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
