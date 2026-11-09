defmodule EEVM.Context.Transaction do
  @moduledoc deprecated: "Use EEVM.TxEnv"
  @moduledoc """
  Deprecated: renamed to `EEVM.TxEnv`, with `gasprice` renamed to
  `gas_price`. `new/1` still accepts the old field name for one minor
  version.
  """

  @doc "Builds an `EEVM.TxEnv`, accepting the old `gasprice` field name."
  @deprecated "Use EEVM.TxEnv.new/1"
  @spec new(keyword()) :: EEVM.TxEnv.t()
  def new(opts \\ []) do
    opts
    |> Enum.map(fn
      {:gasprice, value} -> {:gas_price, value}
      other -> other
    end)
    |> EEVM.TxEnv.new()
  end
end
