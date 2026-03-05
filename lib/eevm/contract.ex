defmodule EEVM.Contract do
  @moduledoc """
  Contract/message-level context — the current call frame's environment.

  ## EVM Concepts

  Each call frame (triggered by CALL, DELEGATECALL, etc.) has its own message
  context. This is the innermost of the three context layers and changes with
  every nested call.

  In revm, this maps to the `Host` trait's per-frame data.

  ### Fields

  | Field | Opcode | Description |
  |-------|--------|-------------|
  | `address` | ADDRESS (0x30) | Address of the executing contract |
  | `caller` | CALLER (0x33) | Direct caller of this frame (msg.sender) |
  | `callvalue` | CALLVALUE (0x34) | ETH (wei) sent with this call |
  | `calldata` | CALLDATALOAD/SIZE/COPY | Input data for this call |
  | `balances` | BALANCE/SELFBALANCE | Account balance lookup |

  ### Caller vs Origin

  - `caller` (CALLER/msg.sender) = who directly called this contract.
    Changes with each nested CALL.
  - `origin` (ORIGIN/tx.origin, in `EEVM.Transaction`) = the EOA that
    signed the transaction. Never changes.

  Example: EOA → Contract A → Contract B
  - In Contract B: `caller` = A, `origin` = EOA

  ## Elixir Learning Notes

  - `calldata` is a raw binary (`<<>>`). Elixir's binary pattern matching
    makes zero-copy slicing trivial via `binary_part/3`.
  - `calldata_load/2` implements EVM spec behavior: reads 32 bytes from an
    offset, right-padding with zeros if calldata is shorter than offset+32.
  - `balances` is a simplified model — a real EVM would query a state database.
  """

  @type t :: %__MODULE__{
          address: non_neg_integer(),
          caller: non_neg_integer(),
          callvalue: non_neg_integer(),
          calldata: binary(),
          balances: %{non_neg_integer() => non_neg_integer()}
        }

  defstruct address: 0,
            caller: 0,
            callvalue: 0,
            calldata: <<>>,
            balances: %{}

  @doc "Creates a new contract context with default values."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a new contract context with the given overrides.

  ## Example

      iex> contract = EEVM.Contract.new(caller: 0xDEAD, callvalue: 1000)
      iex> contract.caller
      0xDEAD
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end

  @doc """
  Returns the balance of an address. Returns 0 for unknown addresses.
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
end
