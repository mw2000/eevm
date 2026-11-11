defmodule EEVM.TransactionError do
  @moduledoc """
  A rejected transaction with the values that broke the rule, returned as
  `{:error, %EEVM.TransactionError{}}` by `EEVM.transact/4` when it is called
  with `details: true`. Without that option the same failure returns the
  bare `reason` atom, which stays the stable, matchable part.

  | Field | Description |
  |-------|-------------|
  | `reason` | The error atom, as listed in `EEVM.Error` |
  | `details` | The values the rule compared, in a map; empty for rules with nothing to compare |

  `details` by `reason` (addresses are integers, amounts in wei, gas in
  units of gas):

  | Reason | Details |
  |--------|---------|
  | `:nonce_too_low`, `:nonce_too_high`, `:nonce_is_max` | `sender`, `tx_nonce`, `state_nonce` |
  | `:insufficient_balance` | `sender`, `balance`, `required` (gas limit at the maximum price, blob gas, and value) |
  | `:intrinsic_gas_too_low` | `gas_limit`, `intrinsic_gas` (the EIP-7623 floor included from Prague) |
  | `:gas_limit_exceeds_block` | `gas_limit`, `block_gas_limit` |
  | `:gas_limit_exceeds_cap` | `gas_limit`, `cap` (EIP-7825) |
  | `:max_fee_below_basefee` | `max_fee_per_gas`, or `gas_price` for legacy and EIP-2930 transactions, and `base_fee` |
  | `:priority_fee_above_max_fee` | `max_priority_fee_per_gas`, `max_fee_per_gas` |
  | `:blob_fee_too_low` | `max_fee_per_blob_gas`, `blob_base_fee` |
  | `:too_many_blobs` | `blobs`, `max_blobs` |
  | `:invalid_versioned_hash`, `:invalid_authorization` | `index` of the first bad entry |
  | `:initcode_too_large` | `size`, `max_size` (EIP-3860) |
  | `:sender_not_eoa` | `sender` |
  | `:tx_type_not_supported` | `type`, `hardfork` |

  `Exception.message/1` and `EEVM.Error.message/1` render it like geth:

      iex> error = %EEVM.TransactionError{reason: :nonce_too_high, details: %{sender: 0xB0B, tx_nonce: 5, state_nonce: 1}}
      iex> Exception.message(error)
      "nonce too high: sender 0x0000000000000000000000000000000000000b0b, tx_nonce 5, state_nonce 1"
  """

  alias EEVM.Error

  @type t :: %__MODULE__{reason: Error.reason(), details: map()}

  defexception [:reason, details: %{}]

  # The order details print in; others follow, sorted.
  @key_order [
    :sender,
    :tx_nonce,
    :state_nonce,
    :balance,
    :required,
    :gas_limit,
    :intrinsic_gas,
    :block_gas_limit,
    :cap,
    :max_priority_fee_per_gas,
    :max_fee_per_gas,
    :gas_price,
    :base_fee,
    :max_fee_per_blob_gas,
    :blob_base_fee,
    :blobs,
    :max_blobs,
    :size,
    :max_size,
    :index,
    :type,
    :hardfork
  ]

  @impl true
  def message(%__MODULE__{reason: reason, details: details}) when map_size(details) == 0,
    do: Error.message(reason)

  def message(%__MODULE__{reason: reason, details: details}) do
    known = for key <- @key_order, Map.has_key?(details, key), do: key
    rest = details |> Map.keys() |> Kernel.--(known) |> Enum.sort()

    rendered =
      Enum.map_join(known ++ rest, ", ", fn key -> "#{key} #{render(key, details[key])}" end)

    "#{Error.message(reason)}: #{rendered}"
  end

  defp render(:sender, address) when is_integer(address), do: EEVM.hex(<<address::160>>)
  defp render(_key, value), do: to_string(value)
end
