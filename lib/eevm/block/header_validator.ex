defmodule EEVM.Block.HeaderValidator do
  @moduledoc """
  Validates a child `EEVM.Block.Header` against its parent.

  Covers the consensus rules that don't require running the EVM:

    * `parent_hash` matches the parent header's `hash`.
    * `number` is one greater than the parent's number.
    * `timestamp` is strictly greater than the parent's timestamp.
    * `extra_data` is at most 32 bytes.
    * `gas_limit` is at least 5,000, fits in a signed 64-bit integer, and
      differs from the parent's gas limit by less than `parent_gas_limit / 1024`.
    * From Cancun, `excess_blob_gas` equals the value derived from the parent
      by `EEVM.Gas.Blob.calc_excess_blob_gas/2` (EIP-4844, with the EIP-7918
      reserve price from Osaka). Skipped when the child's `excess_blob_gas`
      is `nil`.

  Checks run in that order and the first failure wins.

  Cross-checks of `gas_used`, `state_root`, `transactions_root`,
  `receipts_root`, `logs_bloom`, and `withdrawals_root` need the block's
  execution result, so they happen after `EEVM.Block.Processor.process_block/4`
  and aren't covered here. EIP-1559 base-fee rules and the remaining
  EIP-4844 blob-field rules aren't covered yet either.
  """

  alias EEVM.Block.Header
  alias EEVM.Gas.Blob
  alias EEVM.HardforkConfig

  @max_extra_data_size 32
  @max_gas_limit_uint64_signed Bitwise.bsl(1, 63) - 1
  @min_gas_limit 5_000
  @gas_limit_divisor 1_024

  @typedoc "Reason returned when a header fails validation."
  @type error ::
          :unknown_parent
          | :invalid_block_number
          | :invalid_timestamp
          | :extra_data_too_big
          | :invalid_gas_limit
          | :gas_limit_too_big
          | :invalid_excess_blob_gas

  @doc """
  Returns `:ok` when `child` is a valid successor of `parent`, otherwise
  `{:error, reason}` for the first rule it breaks. `hardfork` selects the
  fork-dependent rules and defaults to `EEVM.HardforkConfig.default/0`.

  ## Example

      iex> alias EEVM.Block.{Header, HeaderValidator}
      iex> parent = Header.new(number: 1, timestamp: 10, gas_limit: 30_000_000, hash: <<1::256>>)
      iex> child = Header.new(number: 2, timestamp: 22, gas_limit: 30_000_000, parent_hash: <<1::256>>)
      iex> HeaderValidator.validate(child, parent)
      :ok
      iex> HeaderValidator.validate(%{child | timestamp: 10}, parent)
      {:error, :invalid_timestamp}
  """
  @spec validate(Header.t(), Header.t(), HardforkConfig.t()) :: :ok | {:error, error()}
  def validate(
        %Header{} = child,
        %Header{} = parent,
        %HardforkConfig{} = hardfork \\ HardforkConfig.default()
      ) do
    with :ok <- check_parent_hash(child, parent),
         :ok <- check_number(child, parent),
         :ok <- check_timestamp(child, parent),
         :ok <- check_extra_data(child),
         :ok <- check_gas_limit(child, parent) do
      check_excess_blob_gas(child, parent, hardfork)
    end
  end

  defp check_parent_hash(%Header{parent_hash: ph}, %Header{hash: ph}), do: :ok
  defp check_parent_hash(_, _), do: {:error, :unknown_parent}

  defp check_number(%Header{number: n}, %Header{number: pn}) when n == pn + 1, do: :ok
  defp check_number(_, _), do: {:error, :invalid_block_number}

  defp check_timestamp(%Header{timestamp: t}, %Header{timestamp: pt}) when t > pt, do: :ok
  defp check_timestamp(_, _), do: {:error, :invalid_timestamp}

  defp check_extra_data(%Header{extra_data: data}) when byte_size(data) <= @max_extra_data_size,
    do: :ok

  defp check_extra_data(_), do: {:error, :extra_data_too_big}

  defp check_gas_limit(%Header{gas_limit: limit}, _) when limit < @min_gas_limit,
    do: {:error, :invalid_gas_limit}

  defp check_gas_limit(%Header{gas_limit: limit}, _) when limit > @max_gas_limit_uint64_signed,
    do: {:error, :gas_limit_too_big}

  defp check_gas_limit(%Header{gas_limit: limit}, %Header{gas_limit: parent_limit}) do
    bound = div(parent_limit, @gas_limit_divisor)

    if abs(limit - parent_limit) >= bound do
      {:error, :invalid_gas_limit}
    else
      :ok
    end
  end

  defp check_excess_blob_gas(%Header{excess_blob_gas: nil}, _parent, _hardfork), do: :ok

  defp check_excess_blob_gas(%Header{excess_blob_gas: excess}, parent, hardfork) do
    cond do
      not HardforkConfig.enabled?(hardfork, :eip_4844) -> :ok
      excess == Blob.calc_excess_blob_gas(parent, hardfork) -> :ok
      true -> {:error, :invalid_excess_blob_gas}
    end
  end
end
