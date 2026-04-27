defmodule EEVM.HardforkConfig do
  @moduledoc """
  Hardfork-level feature gating: `enabled?(config, :eip_*)` answers whether
  a given EIP is active for the configured `spec_id` (Frontier through
  Prague). Hardforks are totally ordered by `@spec_order`; each is a
  superset of all earlier rules.

  `default/0` returns Cancun for backwards compatibility with existing
  call sites that don't pass a config.
  """

  @type spec_id ::
          :frontier
          | :homestead
          | :tangerine_whistle
          | :spurious_dragon
          | :byzantium
          | :constantinople
          | :istanbul
          | :berlin
          | :london
          | :paris
          | :shanghai
          | :cancun
          | :prague

  @type t :: %__MODULE__{
          spec_id: spec_id()
        }

  @enforce_keys [:spec_id]
  defstruct [:spec_id]

  @spec_order %{
    frontier: 0,
    homestead: 1,
    tangerine_whistle: 2,
    spurious_dragon: 3,
    byzantium: 4,
    constantinople: 5,
    istanbul: 6,
    berlin: 7,
    london: 8,
    paris: 9,
    shanghai: 10,
    cancun: 11,
    prague: 12
  }

  # Maps each EIP feature flag to the first hardfork that activates it.
  @eip_activation %{
    # EIP-150 (Tangerine Whistle): IO-heavy opcode repricing
    eip_150: :tangerine_whistle,
    # EIP-161 (Spurious Dragon): empty-account clearing
    eip_161: :spurious_dragon,
    # EIP-170 (Spurious Dragon): 24,576-byte runtime code size limit
    eip_170: :spurious_dragon,
    # EIP-1014 (Constantinople): CREATE2 opcode
    eip_1014: :constantinople,
    # EIP-2200 (Istanbul): structured SSTORE net metering
    eip_2200: :istanbul,
    # EIP-2929 (Berlin): cold/warm address & storage access costs
    eip_2929: :berlin,
    # EIP-3529 (London): reduce gas refunds (cap at 1/5 of gas used)
    eip_3529: :london,
    # EIP-3541 (London): reject runtime code with 0xEF prefix (EOF reserved)
    eip_3541: :london,
    # EIP-3651 (Shanghai): COINBASE pre-warmed at tx start
    eip_3651: :shanghai,
    # EIP-3855 (Shanghai): PUSH0 opcode
    eip_3855: :shanghai,
    # EIP-3860 (Shanghai): initcode size limit (2 × 24,576 = 49,152 bytes)
    eip_3860: :shanghai,
    # EIP-1153 (Cancun): transient storage (TLOAD/TSTORE)
    eip_1153: :cancun,
    # EIP-4844 (Cancun): blob transactions, BLOBHASH, BLOBBASEFEE
    eip_4844: :cancun,
    # EIP-5656 (Cancun): MCOPY opcode
    eip_5656: :cancun,
    # EIP-6780 (Cancun): SELFDESTRUCT only deletes if created this tx
    eip_6780: :cancun,
    # EIP-4788 (Cancun): parent beacon block root system contract at 0x000F3df6...Beac02
    eip_4788: :cancun,
    # EIP-2537 (Prague): BLS12-381 precompiles at 0x0B-0x11
    eip_2537: :prague,
    # EIP-7623 (Prague): calldata floor pricing
    eip_7623: :prague,
    # EIP-2935 (Prague): historical block hashes system contract at 0x0000F908...2935
    eip_2935: :prague
  }

  @doc """
  Creates a new config for the given `spec_id`.

      iex> EEVM.HardforkConfig.new(:cancun)
      %EEVM.HardforkConfig{spec_id: :cancun}
  """
  @spec new(spec_id()) :: t()
  def new(spec_id) when is_map_key(@spec_order, spec_id) do
    %__MODULE__{spec_id: spec_id}
  end

  @doc """
  Returns `true` if the given EIP feature flag is active in this hardfork config.

  ## Examples

      iex> config = EEVM.HardforkConfig.new(:cancun)
      iex> EEVM.HardforkConfig.enabled?(config, :eip_6780)
      true

      iex> config = EEVM.HardforkConfig.new(:london)
      iex> EEVM.HardforkConfig.enabled?(config, :eip_6780)
      false

      iex> config = EEVM.HardforkConfig.new(:berlin)
      iex> EEVM.HardforkConfig.enabled?(config, :eip_2929)
      true
  """
  @spec enabled?(t(), atom()) :: boolean()
  def enabled?(%__MODULE__{spec_id: spec_id}, eip_flag) do
    case Map.fetch(@eip_activation, eip_flag) do
      {:ok, activation_fork} ->
        Map.fetch!(@spec_order, spec_id) >= Map.fetch!(@spec_order, activation_fork)

      :error ->
        false
    end
  end

  @doc "Default config (Cancun) for callers that don't specify a hardfork."
  @spec default() :: t()
  def default, do: new(:cancun)

  @doc "All known spec IDs in chronological order."
  @spec all_spec_ids() :: [spec_id()]
  def all_spec_ids do
    @spec_order
    |> Enum.sort_by(fn {_k, v} -> v end)
    |> Enum.map(fn {k, _v} -> k end)
  end
end
