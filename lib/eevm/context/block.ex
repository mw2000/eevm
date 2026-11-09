defmodule EEVM.Context.Block do
  @moduledoc deprecated: "Use EEVM.BlockEnv"
  @moduledoc """
  Deprecated: renamed to `EEVM.BlockEnv` with snake_case fields. `new/1`
  still accepts the old field names for one minor version.
  """

  @renames %{
    gaslimit: :gas_limit,
    prevrandao: :prev_randao,
    basefee: :base_fee,
    hashes: :block_hashes
  }

  @doc """
  Builds an `EEVM.BlockEnv` from the old field names (`gaslimit`,
  `prevrandao`, `basefee`, `hashes`). `chain_id` is dropped: set it with
  `EEVM.Config.new/2`.
  """
  @deprecated "Use EEVM.BlockEnv.new/1"
  @spec new(keyword()) :: EEVM.BlockEnv.t()
  def new(opts \\ []) do
    opts
    |> Keyword.delete(:chain_id)
    |> Enum.map(fn {key, value} -> {Map.get(@renames, key, key), value} end)
    |> EEVM.BlockEnv.new()
  end
end
