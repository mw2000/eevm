defmodule EEVM.TestSupport.BlockchainHeaderValidator do
  @moduledoc """
  Validates a child block header against its parent.

  Covers the consensus rules that don't require running the EVM:

    * `parent_hash` matches the parent header's hash.
    * `number` is one greater than the parent's number.
    * `timestamp` is strictly greater than the parent's timestamp.
    * `extra_data` is at most 32 bytes.
    * `gas_limit` is non-zero, fits in a signed 64-bit integer, and stays
      within the 1/1024 elasticity bound around the parent.

  Returns `:ok` or `{:error, reason}`. Reasons are atoms aimed at
  `BlockchainTest` `expectException` strings, but the runner only checks
  for *any* error when an exception is expected — the specific atom is
  informational.

  Cross-checks of `gas_used`, `state_root`, `transactions_root`,
  `receipts_root`, `logs_bloom`, and `withdrawals_root` happen after the
  block is processed and aren't covered here.
  """

  @max_extra_data_size 32
  @max_gas_limit_uint64_signed Bitwise.bsl(1, 63) - 1
  @min_gas_limit 5_000
  @gas_limit_divisor 1_024

  # We accept any map carrying the documented header fields rather than the
  # fixture's BlockHeader struct directly, so this module can compile before
  # the fixture module loads (they live in the same compile group).
  @spec validate(map(), map()) :: :ok | {:error, atom()}
  def validate(child, parent) when is_map(child) and is_map(parent) do
    with :ok <- check_parent_hash(child, parent),
         :ok <- check_number(child, parent),
         :ok <- check_timestamp(child, parent),
         :ok <- check_extra_data(child) do
      check_gas_limit(child, parent)
    end
  end

  defp check_parent_hash(%{parent_hash: ph}, %{hash: ph}), do: :ok
  defp check_parent_hash(_, _), do: {:error, :unknown_parent}

  defp check_number(%{number: n}, %{number: pn}) when n == pn + 1, do: :ok
  defp check_number(_, _), do: {:error, :invalid_block_number}

  defp check_timestamp(%{timestamp: t}, %{timestamp: pt}) when t > pt, do: :ok
  defp check_timestamp(_, _), do: {:error, :invalid_timestamp}

  defp check_extra_data(%{extra_data: data}) when byte_size(data) <= @max_extra_data_size, do: :ok
  defp check_extra_data(_), do: {:error, :extra_data_too_big}

  defp check_gas_limit(%{gas_limit: limit}, _) when limit < @min_gas_limit,
    do: {:error, :invalid_gas_limit}

  defp check_gas_limit(%{gas_limit: limit}, _) when limit > @max_gas_limit_uint64_signed,
    do: {:error, :gas_limit_too_big}

  defp check_gas_limit(%{gas_limit: limit}, %{gas_limit: parent_limit}) do
    bound = div(parent_limit, @gas_limit_divisor)

    if abs(limit - parent_limit) >= bound do
      {:error, :invalid_gas_limit}
    else
      :ok
    end
  end
end
