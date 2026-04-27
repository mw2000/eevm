defmodule EEVM.Context.Contract do
  @moduledoc """
  Per-frame message context: `address` (ADDRESS), `caller` (CALLER /
  msg.sender), `callvalue` (CALLVALUE), `calldata`, and a small in-frame
  `balances` cache used by BALANCE/SELFBALANCE when no `Database` is wired in.

  Pushed and popped with each nested CALL/DELEGATECALL/STATICCALL. `caller`
  changes with every frame; the surrounding `Transaction.origin` does not.
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

      iex> contract = EEVM.Context.Contract.new(caller: 0xDEAD, callvalue: 1000)
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
  CALLDATALOAD: reads 32 bytes from `offset` as a uint256, zero-padding on
  the right when calldata is shorter than `offset + 32`.
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
