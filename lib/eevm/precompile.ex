defmodule EEVM.Precompile do
  @moduledoc """
  Behaviour for EVM precompile implementations.
  """

  @callback execute(binary(), non_neg_integer()) ::
              {:ok, binary(), non_neg_integer()} | {:error, atom()}
end
