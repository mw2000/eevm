defmodule EEVM.Config do
  @moduledoc """
  Runtime configuration for EEVM execution: the hardfork whose rules apply,
  the chain id, and any custom precompiles.

  Every entry point takes a config as its `:config` option, or the shorthand
  `:hardfork` (a fork atom) for a mainnet config of that fork.

  ## Example

      iex> config = EEVM.Config.new(:prague, chain_id: 11_155_111)
      iex> config.chain_id
      11155111
      iex> EEVM.Config.enabled?(config, :eip_7702)
      true
      iex> EEVM.Config.enabled?(config, :eip_7939)
      false
  """

  alias EEVM.HardforkConfig

  @type t :: %__MODULE__{
          hardfork: HardforkConfig.t(),
          chain_id: non_neg_integer(),
          precompiles: %{optional(non_neg_integer()) => module()}
        }

  defstruct [:hardfork, chain_id: 1, precompiles: %{}]

  @doc """
  Creates a config for `hardfork` (default `:cancun`).

  Options: `:chain_id` (default `1`, mainnet), used for EIP-155 signatures,
  EIP-7702 authorizations, and the CHAINID opcode.

  ## Examples

      iex> EEVM.Config.new()
      %EEVM.Config{hardfork: %EEVM.HardforkConfig{spec_id: :cancun}, chain_id: 1, precompiles: %{}}

      iex> EEVM.Config.new(:berlin, chain_id: 5)
      %EEVM.Config{hardfork: %EEVM.HardforkConfig{spec_id: :berlin}, chain_id: 5, precompiles: %{}}
  """
  @spec new(HardforkConfig.spec_id(), chain_id: non_neg_integer()) :: t()
  def new(hardfork \\ :cancun, opts \\ []) do
    opts = Keyword.validate!(opts, chain_id: 1)
    %__MODULE__{hardfork: HardforkConfig.new(hardfork), chain_id: opts[:chain_id]}
  end

  @doc """
  Returns whether the rule behind `eip_flag` (such as `:eip_1559` or
  `:eip_7702`) is active in `config`'s hardfork.

  Unknown flags are inactive.
  """
  @spec enabled?(t(), atom()) :: boolean()
  def enabled?(%__MODULE__{hardfork: hardfork}, eip_flag),
    do: HardforkConfig.enabled?(hardfork, eip_flag)

  @doc """
  Returns every supported hardfork, oldest first.

  ## Example

      iex> EEVM.Config.hardforks() |> Enum.take(-3)
      [:cancun, :prague, :osaka]
  """
  @spec hardforks() :: [HardforkConfig.spec_id()]
  def hardforks, do: HardforkConfig.all_spec_ids()

  @doc """
  Registers `module`, which implements `EEVM.Precompile`, as a precompile at
  `address`. It replaces a built-in precompile at the same address.
  """
  @spec register_precompile(t(), non_neg_integer(), module()) :: t()
  def register_precompile(%__MODULE__{precompiles: precompiles} = config, address, module)
      when is_integer(address) and address >= 0 and is_atom(module) do
    %{config | precompiles: Map.put(precompiles, address, module)}
  end
end
