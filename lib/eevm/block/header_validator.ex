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
      For London's first block the parent's limit counts double (EIP-1559).
    * Each fork-dependent field is present exactly when its fork is active:
      `base_fee_per_gas` (London), `withdrawals_root` (Shanghai),
      `blob_gas_used`, `excess_blob_gas`, and `parent_beacon_block_root`
      (Cancun), `requests_hash` (Prague).
    * From London, `base_fee_per_gas` equals the value derived from the
      parent's base fee, gas used, and gas target (EIP-1559).
    * Before Paris, `difficulty` is not 0: a proof-of-stake block before the
      terminal total difficulty is invalid. From Paris, `difficulty` is 0,
      `nonce` is eight zero bytes, and `ommers_hash` is
      `EEVM.Block.Header.empty_ommers_hash/0`, so a proof-of-work block after
      it is invalid (EIP-3675). The caller picks Paris for a block once its
      parent's total difficulty reaches the terminal total difficulty.
    * From Cancun, `blob_gas_used` is a multiple of the per-blob gas
      and at most `EEVM.Gas.Blob.max_blob_gas_per_block/1`. `excess_blob_gas`
      equals `EEVM.Gas.Blob.calc_excess_blob_gas/2` of the parent (EIP-4844,
      EIP-7691 from Prague, EIP-7918 from Osaka).

  Checks run in that order and the first failure wins. A parent without a
  base fee under a London-or-later child marks London's first block, whose
  base fee is the initial 1 gwei.

  Checks against the block body and the execution result (`transactions_root`,
  `withdrawals_root`, `gas_used`, `receipts_root`, `state_root`, ...) live in
  `EEVM.Block.validate/3` and `EEVM.Block.execute/4`.
  """

  alias EEVM.Block.Header
  alias EEVM.Gas.Blob
  alias EEVM.HardforkConfig

  @max_extra_data_size 32
  @max_gas_limit_uint64_signed Bitwise.bsl(1, 63) - 1
  @min_gas_limit 5_000
  @gas_limit_divisor 1_024

  # Fork-dependent header fields and the flag that introduces each.
  @fork_fields [
    base_fee_per_gas: :eip_1559,
    withdrawals_root: :eip_4895,
    blob_gas_used: :eip_4844,
    excess_blob_gas: :eip_4844,
    parent_beacon_block_root: :eip_4788,
    requests_hash: :eip_7685
  ]

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
      iex> fields = [base_fee_per_gas: 0, withdrawals_root: <<0::256>>]
      iex> parent = struct!(parent, fields)
      iex> child = Header.new([number: 2, timestamp: 22, gas_limit: 30_000_000, parent_hash: <<1::256>>] ++ fields)
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
         :ok <- check_gas_limit(child, parent, hardfork),
         :ok <- check_fork_fields(child, hardfork),
         :ok <- check_base_fee(child, parent, hardfork),
         :ok <- check_consensus_fields(child, hardfork) do
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

  defp check_gas_limit(%Header{gas_limit: limit}, _, _) when limit < @min_gas_limit,
    do: {:error, :invalid_gas_limit}

  defp check_gas_limit(%Header{gas_limit: limit}, _, _)
       when limit > @max_gas_limit_uint64_signed,
       do: {:error, :gas_limit_too_big}

  defp check_gas_limit(%Header{gas_limit: limit}, %Header{} = parent, hardfork) do
    # EIP-1559: the fork block's parent gas limit is scaled by the elasticity
    # multiplier, so the gas target stays where the old limit was.
    parent_limit =
      if HardforkConfig.enabled?(hardfork, :eip_1559) and parent.base_fee_per_gas == nil,
        do: parent.gas_limit * 2,
        else: parent.gas_limit

    bound = div(parent_limit, @gas_limit_divisor)

    if abs(limit - parent_limit) >= bound do
      {:error, :invalid_gas_limit}
    else
      :ok
    end
  end

  defp check_fork_fields(%Header{} = child, hardfork) do
    Enum.reduce_while(@fork_fields, :ok, fn {field, flag}, :ok ->
      case {HardforkConfig.enabled?(hardfork, flag), Map.fetch!(child, field)} do
        {true, nil} -> {:halt, {:error, :missing_header_fields}}
        {false, value} when value != nil -> {:halt, {:error, :unexpected_header_fields}}
        _ -> {:cont, :ok}
      end
    end)
  end

  defp check_base_fee(%Header{base_fee_per_gas: base_fee}, parent, hardfork) do
    if not HardforkConfig.enabled?(hardfork, :eip_1559) or
         base_fee == Header.calc_base_fee_per_gas(parent),
       do: :ok,
       else: {:error, :invalid_base_fee}
  end

  defp check_consensus_fields(%Header{} = child, hardfork) do
    post_merge? = HardforkConfig.enabled?(hardfork, :eip_3675)

    cond do
      post_merge? != (child.difficulty == 0) -> {:error, :invalid_difficulty}
      not post_merge? -> :ok
      child.nonce != <<0::64>> -> {:error, :invalid_nonce}
      child.ommers_hash != Header.empty_ommers_hash() -> {:error, :invalid_ommers_hash}
      true -> :ok
    end
  end

  defp check_blob_gas(%Header{blob_gas_used: used, excess_blob_gas: excess}, parent, hardfork) do
    cond do
      not HardforkConfig.enabled?(hardfork, :eip_4844) -> :ok
      rem(used, Blob.gas_per_blob()) != 0 -> {:error, :invalid_blob_gas_used}
      used > Blob.max_blob_gas_per_block(hardfork) -> {:error, :invalid_blob_gas_used}
      excess != Blob.calc_excess_blob_gas(parent, hardfork) -> {:error, :invalid_excess_blob_gas}
      true -> :ok
    end
  end
end
