defmodule EEVM.TxEnv do
  @moduledoc """
  The transaction environment code executes in: the signed transaction as
  the EVM sees it. `EEVM.transact/4` builds one from the wire transaction;
  set it yourself only to give bytecode run with `EEVM.run/2` a transaction
  context, through its `:tx` option.

  ### Fields

  | Field | Opcode | Description |
  |-------|--------|-------------|
  | `type` | — | `:legacy`, `:eip2930`, `:eip1559`, `:eip4844`, or `:eip7702` |
  | `origin` | ORIGIN (0x32) | The externally owned account (EOA) that signed the tx |
  | `gas_price` | GASPRICE (0x3A) | Effective gas price in wei the sender pays |
  | `nonce` | — | The sender's nonce |
  | `gas_limit` | — | The transaction's gas limit |
  | `to` | — | The recipient address, or `nil` for a contract creation |
  | `value` | — | Wei sent with the call |
  | `data` | — | Calldata, or initcode for a creation |
  | `max_fee_per_gas`, `max_priority_fee_per_gas` | — | EIP-1559 fee caps in wei |
  | `max_fee_per_blob_gas` | — | EIP-4844 blob fee cap in wei |
  | `blob_hashes` | BLOBHASH (0x49) | List of blob versioned hashes from EIP-4844 transaction payload |
  | `access_list` | — | EIP-2930 `[{address, [slot]}]` warmed before execution |
  | `authorization_list` | — | EIP-7702 authorizations applied before execution |

  ### Origin vs Caller

  `origin` is always the EOA that signed the transaction — it never changes,
  even through nested contract calls. The caller (CALLER, and `EEVM.run/2`'s
  `:caller` option) is the *direct* caller of the current frame and changes
  with each CALL.
  """

  @type t :: %__MODULE__{
          origin: non_neg_integer(),
          gas_price: non_neg_integer(),
          blob_hashes: [non_neg_integer()],
          nonce: non_neg_integer(),
          gas_limit: non_neg_integer(),
          to: non_neg_integer() | nil,
          value: non_neg_integer(),
          data: binary(),
          max_fee_per_gas: non_neg_integer(),
          max_priority_fee_per_gas: non_neg_integer(),
          access_list: [{non_neg_integer(), [non_neg_integer()]}],
          authorization_list: [authorization()],
          max_fee_per_blob_gas: non_neg_integer(),
          type: :legacy | :eip2930 | :eip1559 | :eip4844 | :eip7702
        }

  @type authorization :: %{
          required(:chain_id) => non_neg_integer(),
          required(:address) => non_neg_integer(),
          required(:nonce) => non_neg_integer(),
          required(:y_parity) => 0..255,
          required(:r) => non_neg_integer(),
          required(:s) => non_neg_integer()
        }

  defstruct origin: 0,
            gas_price: 0,
            blob_hashes: [],
            nonce: 0,
            gas_limit: 0,
            to: nil,
            value: 0,
            data: <<>>,
            max_fee_per_gas: 0,
            max_priority_fee_per_gas: 0,
            access_list: [],
            authorization_list: [],
            max_fee_per_blob_gas: 0,
            type: :legacy

  @doc "Creates a new transaction environment with default values."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a new transaction environment with the given overrides.

  ## Example

      iex> tx = EEVM.TxEnv.new(origin: 0xDEAD, gas_price: 20_000_000_000)
      iex> tx.origin
      0xDEAD
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end
end
