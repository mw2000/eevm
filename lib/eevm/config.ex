defmodule EEVM.Config do
  @moduledoc """
  Runtime configuration for EEVM execution.

  Holds both the hardfork specification (which EIP rules are active) and
  custom precompile registration.
  """

  alias EEVM.HardforkConfig

  @type t :: %__MODULE__{
          hardfork: HardforkConfig.t(),
          precompiles: %{optional(non_neg_integer()) => module()}
        }

  defstruct hardfork: nil,
            precompiles: %{}

  @doc """
  Creates a new config with the given hardfork (default: `:cancun`).

  ## Examples

      iex> EEVM.Config.new()
      %EEVM.Config{hardfork: %EEVM.HardforkConfig{spec_id: :cancun}, precompiles: %{}}

      iex> EEVM.Config.new(:berlin)
      %EEVM.Config{hardfork: %EEVM.HardforkConfig{spec_id: :berlin}, precompiles: %{}}
  """
  @spec new(HardforkConfig.spec_id()) :: t()
  def new(spec_id \\ :cancun) do
    %__MODULE__{hardfork: HardforkConfig.new(spec_id)}
  end

  @spec register_precompile(t(), non_neg_integer(), module()) :: t()
  def register_precompile(%__MODULE__{precompiles: precompiles} = config, address, module)
      when is_integer(address) and address >= 0 and is_atom(module) do
    %{config | precompiles: Map.put(precompiles, address, module)}
  end
end
