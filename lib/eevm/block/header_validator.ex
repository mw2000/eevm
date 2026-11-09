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
    * From London, `base_fee_per_gas` equals the value derived from the
      parent's base fee, gas used, and gas target (EIP-1559).
    * From Paris, `difficulty` is 0, `nonce` is eight zero bytes, and
      `ommers_hash` is `EEVM.Block.Header.empty_ommers_hash/0` (EIP-3675).
    * From Cancun, `blob_gas_used` and `excess_blob_gas` are present (and
      absent before Cancun). `blob_gas_used` is a multiple of the per-blob gas
      and at most `EEVM.Gas.Blob.max_blob_gas_per_block/1`. `excess_blob_gas`
      equals `EEVM.Gas.Blob.calc_excess_blob_gas/2` of the parent (EIP-4844,
      EIP-7691 from Prague, EIP-7918 from Osaka).

  Checks run in that order and the first failure wins. The parent is judged
  under the same fork as the child, so a fork's first block (such as London's,
  whose expected base fee is the initial 1 gwei) isn't modelled.

  Cross-checks of `gas_used`, `state_root`, `transactions_root`,
  `receipts_root`, `logs_bloom`, and `withdrawals_root` need the block's
  execution result, so they happen after `EEVM.Block.Processor.process_block/4`
  and aren't covered here.
  """

  alias EEVM.Block.Header
  alias EEVM.Gas.Blob
  alias EEVM.HardforkConfig

  @max_extra_data_size 32
  @max_gas_limit_uint64_signed Bitwise.bsl(1, 63) - 1
  @min_gas_limit 5_000
  @gas_limit_divisor 1_024
  # EIP-1559
  @elasticity_multiplier 2
  @base_fee_max_change_denominator 8

  @typedoc "Reason returned when a header fails validation; see `EEVM.Error`."
  @type error :: EEVM.Error.header_validation_error()

  @doc """
  Returns `:ok` when `child` is a valid successor of `parent`, otherwise
  `{:error, reason}` for the first rule it breaks. `hardfork` selects the
  fork-dependent rules and defaults to `EEVM.HardforkConfig.default/0`.

  ## Example

      iex> alias EEVM.Block.{Header, HeaderValidator}
      iex> shanghai = EEVM.HardforkConfig.new(:shanghai)
      iex> parent = Header.new(number: 1, timestamp: 10, gas_limit: 30_000_000, hash: <<1::256>>)
      iex> child = Header.new(number: 2, timestamp: 22, gas_limit: 30_000_000, parent_hash: <<1::256>>)
      iex> HeaderValidator.validate(child, parent, shanghai)
      :ok
      iex> HeaderValidator.validate(%{child | timestamp: 10}, parent, shanghai)
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
         :ok <- check_gas_limit(child, parent),
         :ok <- check_base_fee(child, parent, hardfork),
         :ok <- check_post_merge_fields(child, hardfork) do
      check_blob_gas(child, parent, hardfork)
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

  defp check_base_fee(%Header{base_fee_per_gas: base_fee}, parent, hardfork) do
    if not HardforkConfig.enabled?(hardfork, :eip_1559) or base_fee == expected_base_fee(parent),
      do: :ok,
      else: {:error, :invalid_base_fee}
  end

  # EIP-1559 calculate_base_fee_per_gas: move the parent's base fee by at most
  # 1/8 towards the parent's gas use relative to its target (gas_limit / 2).
  defp expected_base_fee(%Header{gas_limit: limit, gas_used: used, base_fee_per_gas: fee}) do
    target = div(limit, @elasticity_multiplier)

    cond do
      used == target ->
        fee

      used > target ->
        fee + max(div(div(fee * (used - target), target), @base_fee_max_change_denominator), 1)

      true ->
        fee - div(div(fee * (target - used), target), @base_fee_max_change_denominator)
    end
  end

  defp check_post_merge_fields(%Header{} = child, hardfork) do
    cond do
      not HardforkConfig.enabled?(hardfork, :eip_3675) -> :ok
      child.difficulty != 0 -> {:error, :invalid_difficulty}
      child.nonce != <<0::64>> -> {:error, :invalid_nonce}
      child.ommers_hash != Header.empty_ommers_hash() -> {:error, :invalid_ommers_hash}
      true -> :ok
    end
  end

  defp check_blob_gas(%Header{blob_gas_used: used, excess_blob_gas: excess}, parent, hardfork) do
    blob_fork? = HardforkConfig.enabled?(hardfork, :eip_4844)

    cond do
      not blob_fork? and used == nil and excess == nil -> :ok
      not blob_fork? -> {:error, :unexpected_blob_fields}
      used == nil or excess == nil -> {:error, :missing_blob_fields}
      rem(used, Blob.gas_per_blob()) != 0 -> {:error, :invalid_blob_gas_used}
      used > Blob.max_blob_gas_per_block(hardfork) -> {:error, :invalid_blob_gas_used}
      excess != Blob.calc_excess_blob_gas(parent, hardfork) -> {:error, :invalid_excess_blob_gas}
      true -> :ok
    end
  end
end
