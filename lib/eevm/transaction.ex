defmodule EEVM.Transaction do
  @moduledoc """
  Transaction-level context — information about the original transaction.

  ## EVM Concepts

  Every EVM execution is triggered by a transaction. The transaction context
  captures who initiated the transaction and the gas economics they agreed to.

  In a production EVM (like revm), this is the `Transaction` trait — one of
  three context layers that the VM reads from via environment opcodes.

  ### Fields

  | Field | Opcode | Description |
  |-------|--------|-------------|
  | `origin` | ORIGIN (0x32) | The externally owned account (EOA) that signed the tx |
  | `gasprice` | GASPRICE (0x3A) | Gas price in wei the sender is paying |

  ### Origin vs Caller

  `origin` is always the EOA that signed the transaction — it never changes,
  even through nested contract calls. `caller` (in `EEVM.Contract`) is the
  *direct* caller of the current frame and changes with each CALL.

  ## Elixir Learning Notes

  - This is a simple struct with `struct!/2` for construction with validation.
  - `new/0` and `new/1` pattern shows how to provide both zero-arg and keyword
    constructors idiomatically.
  """

  @type t :: %__MODULE__{
          origin: non_neg_integer(),
          gasprice: non_neg_integer()
        }

  defstruct origin: 0,
            gasprice: 0

  @doc "Creates a new transaction context with default values."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a new transaction context with the given overrides.

  ## Example

      iex> tx = EEVM.Transaction.new(origin: 0xDEAD, gasprice: 20_000_000_000)
      iex> tx.origin
      0xDEAD
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end
end
