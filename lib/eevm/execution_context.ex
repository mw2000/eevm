defmodule EEVM.ExecutionContext do
  @moduledoc """
  The execution environment — external information available to the EVM.

  ## EVM Concepts

  The EVM doesn't execute in a vacuum. Every execution has a *context* — who
  called the contract, how much ETH they sent, what block it's running in,
  what data they passed as input. Environment opcodes let contracts read
  this context.

  This is the "Host" interface — revm calls it `ContextTr`, the Yellow Paper
  calls it the execution environment `I`.

  ### Three Layers of Context

  1. **Transaction** — who sent the tx (`origin`), what gas price they're paying
  2. **Message** — the current call frame: `caller`, `value`, `calldata`, `address`
  3. **Block** — the block being built: `number`, `timestamp`, `coinbase`, `gaslimit`, etc.

  ### Opcodes That Read Context

  | Opcode | Byte | Reads | Gas |
  |--------|------|-------|-----|
  | ADDRESS | 0x30 | Current contract address | 2 |
  | BALANCE | 0x31 | Balance of an address | 2600 (cold) |
  | ORIGIN | 0x32 | Transaction sender (EOA) | 2 |
  | CALLER | 0x33 | Direct caller of this frame | 2 |
  | CALLVALUE | 0x34 | ETH sent with this call | 2 |
  | CALLDATALOAD | 0x35 | 32 bytes of calldata at offset | 3 |
  | CALLDATASIZE | 0x36 | Length of calldata | 2 |
  | CALLDATACOPY | 0x37 | Copy calldata to memory | 3 + mem |
  | CODESIZE | 0x38 | Size of executing code | 2 |
  | GASPRICE | 0x3A | Gas price of the tx | 2 |
  | RETURNDATASIZE | 0x3D | Size of last return data | 2 |
  | BLOCKHASH | 0x40 | Hash of a recent block | 20 |
  | COINBASE | 0x41 | Block producer's address | 2 |
  | TIMESTAMP | 0x42 | Block timestamp | 2 |
  | NUMBER | 0x43 | Block number | 2 |
  | PREVRANDAO | 0x44 | Previous block's RANDAO value | 2 |
  | GASLIMIT | 0x45 | Block gas limit | 2 |
  | CHAINID | 0x46 | Chain ID (1 = mainnet) | 2 |
  | SELFBALANCE | 0x47 | Balance of executing contract | 5 |
  | BASEFEE | 0x48 | Block base fee (EIP-1559) | 2 |
  | GAS | 0x5A | Remaining gas | 2 |

  ## Elixir Learning Notes

  - We use a flat struct with sensible defaults. In a production EVM (like revm),
    these would be separate traits (`Transaction`, `Block`, `Cfg`), but for
    learning a flat struct is clearer.
  - Default values make it easy to construct partial contexts for testing —
    you only set what you need.
  - The `calldata` field is a raw binary (`<<>>`) — Elixir excels at binary
    pattern matching, which we use in CALLDATALOAD/CALLDATACOPY.
  """

  @type t :: %__MODULE__{
          # Message context (current call frame)
          address: non_neg_integer(),
          caller: non_neg_integer(),
          origin: non_neg_integer(),
          callvalue: non_neg_integer(),
          calldata: binary(),
          gasprice: non_neg_integer(),
          # Block context
          block_number: non_neg_integer(),
          block_timestamp: non_neg_integer(),
          block_coinbase: non_neg_integer(),
          block_gaslimit: non_neg_integer(),
          block_prevrandao: non_neg_integer(),
          block_basefee: non_neg_integer(),
          block_chainid: non_neg_integer(),
          # Account balances — simplified as a map
          balances: %{non_neg_integer() => non_neg_integer()},
          # Block hashes — map of block_number => hash (last 256 blocks)
          block_hashes: %{non_neg_integer() => non_neg_integer()}
        }

  defstruct address: 0,
            caller: 0,
            origin: 0,
            callvalue: 0,
            calldata: <<>>,
            gasprice: 0,
            block_number: 0,
            block_timestamp: 0,
            block_coinbase: 0,
            block_gaslimit: 0,
            block_prevrandao: 0,
            block_basefee: 0,
            block_chainid: 1,
            balances: %{},
            block_hashes: %{}

  @doc "Creates a new execution context with default values."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a new execution context with the given overrides.

  ## Example

      iex> ctx = EEVM.ExecutionContext.new(caller: 0xDEAD, callvalue: 1000)
      iex> ctx.caller
      0xDEAD
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end

  @doc """
  Returns the balance of an address.

  Returns 0 for unknown addresses.
  """
  @spec balance(t(), non_neg_integer()) :: non_neg_integer()
  def balance(%__MODULE__{balances: balances}, address) do
    Map.get(balances, address, 0)
  end

  @doc """
  Reads 32 bytes from calldata starting at the given byte offset.

  Calldata shorter than offset+32 is right-padded with zeros, matching
  EVM spec behavior. This is what CALLDATALOAD does.

  ## Elixir Learning Note

  We use `binary_part/3` with bounds checking and manual zero-padding.
  Elixir binaries are immutable byte sequences — slicing them is O(1).
  """
  @spec calldata_load(t(), non_neg_integer()) :: non_neg_integer()
  def calldata_load(%__MODULE__{calldata: calldata}, offset) do
    size = byte_size(calldata)

    bytes =
      cond do
        offset >= size ->
          <<0::256>>

        offset + 32 > size ->
          available = binary_part(calldata, offset, size - offset)
          pad_len = 32 - byte_size(available)
          available <> <<0::size(pad_len * 8)>>

        true ->
          binary_part(calldata, offset, 32)
      end

    <<value::unsigned-big-256>> = bytes
    value
  end

  @doc """
  Returns the block hash for a given block number.

  Returns 0 if the block number is not in the last 256 blocks.
  """
  @spec block_hash(t(), non_neg_integer()) :: non_neg_integer()
  def block_hash(%__MODULE__{block_hashes: hashes, block_number: current}, number) do
    if number < current and number >= max(0, current - 256) do
      Map.get(hashes, number, 0)
    else
      0
    end
  end
end
