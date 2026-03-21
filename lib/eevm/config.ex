defmodule EEVM.Config do
  @moduledoc """
  Runtime configuration for EEVM execution.

  Currently supports custom precompile registration at arbitrary addresses.
  """

  @type t :: %__MODULE__{precompiles: %{optional(non_neg_integer()) => module()}}

  defstruct precompiles: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec register_precompile(t(), non_neg_integer(), module()) :: t()
  def register_precompile(%__MODULE__{precompiles: precompiles} = config, address, module)
      when is_integer(address) and address >= 0 and is_atom(module) do
    %{config | precompiles: Map.put(precompiles, address, module)}
  end
end
