defmodule EEVM.BlockEnv do
  @moduledoc """
  The block environment a transaction executes in: the fields the EVM's
  block opcodes read. `EEVM.Handler.execute/4` takes one; `EEVM.Block`
  derives it from each header with `from_header/2`.

  The chain id isn't here: it lives in `EEVM.Config` with the rest of the
  chain's rules.

  | Field | Opcode | Description |
  |-------|--------|-------------|
  | `number` | NUMBER (0x43) | Current block number |
  | `timestamp` | TIMESTAMP (0x42) | Block timestamp (seconds since epoch) |
  | `coinbase` | COINBASE (0x41) | Address of the block producer |
  | `gas_limit` | GASLIMIT (0x45) | Block gas limit; defaults to 30,000,000, a mainnet-sized block, so transactions fit |
  | `prev_randao` | PREVRANDAO (0x44) | RANDAO mix from the beacon chain (DIFFICULTY before the Merge) |
  | `base_fee` | BASEFEE (0x48) | Block base fee (EIP-1559) |
  | `blob_base_fee` | BLOBBASEFEE (0x4A) | Block blob base fee (EIP-4844, EIP-7516) |
  | `block_hashes` | BLOCKHASH (0x40) | Recent block numbers mapped to their 32-byte hashes |
  | `parent_beacon_block_root` | — | Parent beacon block root, stored by the EIP-4788 system call |
  """

  alias EEVM.Block.Header
  alias EEVM.Gas.Blob, as: BlobGas
  alias EEVM.Handler.Validation
  alias EEVM.HardforkConfig
  require EEVM.HardforkConfig

  @type t :: %__MODULE__{
          number: non_neg_integer(),
          timestamp: non_neg_integer(),
          coinbase: non_neg_integer(),
          gas_limit: non_neg_integer(),
          prev_randao: non_neg_integer(),
          base_fee: non_neg_integer(),
          blob_base_fee: non_neg_integer(),
          block_hashes: %{non_neg_integer() => <<_::256>>},
          parent_beacon_block_root: <<_::256>>
        }

  defstruct number: 0,
            timestamp: 0,
            coinbase: 0,
            gas_limit: 30_000_000,
            prev_randao: 0,
            base_fee: 0,
            blob_base_fee: 0,
            block_hashes: %{},
            parent_beacon_block_root: <<0::256>>

  @doc """
  Returns the environment of the block `header` describes.

  The blob base fee follows from `header.excess_blob_gas` under the
  hardfork's blob schedule, and `prev_randao` holds the header's difficulty
  before Paris (EIP-4399). Options: `:config` or `:hardfork` (default
  `:cancun`), and `:block_hashes`, recent block numbers mapped to their
  hashes for BLOCKHASH.

  ## Example

      iex> header = EEVM.Block.Header.new(number: 5, gas_limit: 30_000_000, base_fee_per_gas: 7)
      iex> env = EEVM.BlockEnv.from_header(header)
      iex> {env.number, env.gas_limit, env.base_fee}
      {5, 30000000, 7}
  """
  @spec from_header(Header.t(), keyword()) :: t()
  def from_header(%Header{} = header, opts \\ []) do
    hardfork = Validation.resolve_config(opts).hardfork

    %__MODULE__{
      number: header.number,
      timestamp: header.timestamp,
      coinbase: header.coinbase,
      gas_limit: header.gas_limit,
      # Opcode 0x44 is DIFFICULTY before Paris and PREVRANDAO from it (EIP-4399).
      prev_randao:
        if(HardforkConfig.enabled?(hardfork, :eip_4399),
          do: header.prev_randao,
          else: header.difficulty
        ),
      base_fee: header.base_fee_per_gas || 0,
      blob_base_fee:
        if(header.excess_blob_gas,
          do: BlobGas.base_fee_per_blob_gas(header.excess_blob_gas, hardfork),
          else: 0
        ),
      block_hashes: Keyword.get(opts, :block_hashes, %{}),
      parent_beacon_block_root: header.parent_beacon_block_root || <<0::256>>
    }
  end

  @doc """
  Creates a new block environment with default values: block 0 with no base
  fee, and a 30,000,000 gas limit so a transaction can run in it.

      iex> EEVM.BlockEnv.new().gas_limit
      30000000
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a new block environment with the given overrides.

  ## Example

      iex> block = EEVM.BlockEnv.new(number: 18_000_000, base_fee: 7)
      iex> block.number
      18000000
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end

  @doc """
  Returns the hash of block `block_number` as the word BLOCKHASH pushes.

  Returns 0 if the block number is not in the last 256 blocks or is the
  current/future block. This matches the EVM spec — BLOCKHASH can only
  access the most recent 256 ancestors. A hash given as an integer is still
  accepted, for one minor version (deprecated).
  """
  @spec hash(t(), non_neg_integer()) :: non_neg_integer()
  def hash(%__MODULE__{block_hashes: hashes, number: current}, block_number) do
    if block_number < current and block_number >= max(0, current - 256) do
      case Map.get(hashes, block_number, 0) do
        <<hash::unsigned-big-256>> -> hash
        hash when is_integer(hash) -> hash
      end
    else
      0
    end
  end
end
