defmodule EEVM.Gas.Blob do
  @moduledoc """
  Blob gas pricing (EIP-4844) and its later adjustments.

  - `base_fee_per_blob_gas/2` derives the blob base fee exposed by
    BLOBBASEFEE from a header's `excess_blob_gas`.
  - `calc_excess_blob_gas/2` computes the `excess_blob_gas` a child header
    must carry, given its parent.

  The blob schedule (target and max blobs per block, base-fee update
  fraction) follows the active hardfork: EIP-4844 values in Cancun and the
  EIP-7691 increase from Prague. From Osaka, EIP-7918 bounds the blob base
  fee below by execution cost: while `GAS_PER_BLOB * blob_base_fee` is below
  `BLOB_BASE_COST * base_fee_per_gas`, excess blob gas stops shrinking.
  """

  alias EEVM.HardforkConfig

  @gas_per_blob 131_072
  @min_base_fee_per_blob_gas 1
  # EIP-7918
  @blob_base_cost 8_192

  # {target_blobs, max_blobs, base_fee_update_fraction}
  @cancun_schedule {3, 6, 3_338_477}
  @prague_schedule {6, 9, 5_007_716}

  @typedoc "The parent-header fields `calc_excess_blob_gas/2` reads."
  @type parent :: %{
          required(:excess_blob_gas) => non_neg_integer() | nil,
          required(:blob_gas_used) => non_neg_integer() | nil,
          required(:base_fee_per_gas) => non_neg_integer(),
          optional(atom()) => term()
        }

  @doc "Returns the blob gas consumed by one blob (2^17)."
  @spec gas_per_blob() :: pos_integer()
  def gas_per_blob, do: @gas_per_blob

  @doc """
  Returns the most blob gas one block may use: max blobs per block times
  `gas_per_blob/0` (6 blobs in Cancun, 9 from Prague per EIP-7691).

  ## Example

      iex> EEVM.Gas.Blob.max_blob_gas_per_block(EEVM.HardforkConfig.new(:cancun))
      786_432
  """
  @spec max_blob_gas_per_block(HardforkConfig.t()) :: pos_integer()
  def max_blob_gas_per_block(%HardforkConfig{} = hardfork) do
    {_target, max_blobs, _fraction} = schedule(hardfork)
    max_blobs * @gas_per_blob
  end

  @doc """
  Returns the blob base fee for a block carrying `excess_blob_gas`.

  ## Examples

      iex> EEVM.Gas.Blob.base_fee_per_blob_gas(0, EEVM.HardforkConfig.new(:cancun))
      1

      iex> EEVM.Gas.Blob.base_fee_per_blob_gas(10_000_000, EEVM.HardforkConfig.new(:cancun))
      19
  """
  @spec base_fee_per_blob_gas(non_neg_integer(), HardforkConfig.t()) :: pos_integer()
  def base_fee_per_blob_gas(excess_blob_gas, %HardforkConfig{} = hardfork) do
    {_target, _max, update_fraction} = schedule(hardfork)
    fake_exponential(@min_base_fee_per_blob_gas, excess_blob_gas, update_fraction)
  end

  @doc """
  Returns the `excess_blob_gas` a child of `parent` must carry under `hardfork`.

  A `nil` blob field on the parent (a pre-Cancun header) counts as zero.
  """
  @spec calc_excess_blob_gas(parent(), HardforkConfig.t()) :: non_neg_integer()
  def calc_excess_blob_gas(parent, %HardforkConfig{} = hardfork) do
    {target_blobs, max_blobs, _fraction} = schedule(hardfork)
    parent_excess = parent.excess_blob_gas || 0
    parent_used = parent.blob_gas_used || 0
    target_blob_gas = @gas_per_blob * target_blobs

    cond do
      parent_excess + parent_used < target_blob_gas ->
        0

      HardforkConfig.enabled?(hardfork, :eip_7918) and
          @blob_base_cost * parent.base_fee_per_gas >
            @gas_per_blob * base_fee_per_blob_gas(parent_excess, hardfork) ->
        parent_excess + div(parent_used * (max_blobs - target_blobs), max_blobs)

      true ->
        parent_excess + parent_used - target_blob_gas
    end
  end

  @doc """
  Approximates `factor * e ** (numerator / denominator)` with integer math,
  as specified by EIP-4844.

  ## Example

      iex> EEVM.Gas.Blob.fake_exponential(1, 0, 3_338_477)
      1
  """
  @spec fake_exponential(non_neg_integer(), non_neg_integer(), pos_integer()) ::
          non_neg_integer()
  def fake_exponential(factor, numerator, denominator) do
    fake_exponential_sum(1, 0, factor * denominator, numerator, denominator)
  end

  defp fake_exponential_sum(_i, output, 0, _numerator, denominator),
    do: div(output, denominator)

  defp fake_exponential_sum(i, output, accum, numerator, denominator) do
    next_accum = div(accum * numerator, denominator * i)
    fake_exponential_sum(i + 1, output + accum, next_accum, numerator, denominator)
  end

  defp schedule(hardfork) do
    if HardforkConfig.enabled?(hardfork, :eip_7691), do: @prague_schedule, else: @cancun_schedule
  end
end
