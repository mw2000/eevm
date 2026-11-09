defmodule EEVM.HardforkConfig do
  @moduledoc """
  Hardfork configuration controlling which EIP rules are active during execution.

  The `spec_id` atom identifies the target hardfork, and `enabled?/2` answers
  whether a given EIP is active under that spec.

  Hardfork timeline (oldest → newest):

  | Hardfork         | Notable EIPs |
  |------------------|--------------|
  | `:frontier`      | baseline     |
  | `:homestead`     | EIP-2 (contract-creation tx cost), EIP-7 (DELEGATECALL) |
  | `:tangerine_whistle` | EIP-150 gas repricing |
  | `:spurious_dragon` | EIP-155, EIP-160 (EXP cost), EIP-161, EIP-170 (code size limit) |
  | `:byzantium`     | EIP-140 (REVERT), EIP-196/197 (alt_bn128 precompiles), EIP-198 (ModExp precompile), EIP-211 (RETURNDATASIZE/RETURNDATACOPY), EIP-214 (STATICCALL) |
  | `:constantinople` | EIP-1014 (CREATE2), EIP-145 (SHL/SHR/SAR), EIP-1052 (EXTCODEHASH) |
  | `:istanbul`      | EIP-152 (BLAKE2F precompile), EIP-1108 (alt_bn128 repricing), EIP-1344 (CHAINID), EIP-1884 (SELFBALANCE), EIP-2028 (calldata cost), EIP-2200 (SSTORE) |
  | `:berlin`        | EIP-2565 (ModExp repricing), EIP-2929 (cold/warm access), EIP-2930 (access lists) |
  | `:london`        | EIP-1559 (basefee), EIP-3198 (BASEFEE), EIP-3529 (refund cap), EIP-3541 (0xEF rejection) |
  | `:paris`         | The Merge (PREVRANDAO replaces DIFFICULTY) |
  | `:shanghai`      | EIP-3651 (COINBASE pre-warm), EIP-3855 (PUSH0), EIP-3860 (initcode limit) |
  | `:cancun`        | EIP-1153 (TLOAD/TSTORE), EIP-4844 (blobs, BLOBHASH, KZG precompile), EIP-5656 (MCOPY), EIP-6780 (SELFDESTRUCT), EIP-7516 (BLOBBASEFEE) |
  | `:prague`        | EIP-2537 (BLS12-381 precompiles), EIP-7623 (calldata floor), EIP-7702 (set-code) |
  |                  | EIP-2935 (block hashes), EIP-7685 requests: EIP-6110 deposits, EIP-7002 withdrawals, EIP-7251 consolidations |
  | `:osaka`         | EIP-7825 (tx gas limit cap), EIP-7918 (blob base fee floor), EIP-7934 (block RLP size limit), EIP-7939 (CLZ) |
  |                  | EIP-7823 (ModExp bounds), EIP-7883 (ModExp repricing), EIP-7951 (P256VERIFY precompile) |
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
          | :osaka

  @type t :: %__MODULE__{
          spec_id: spec_id()
        }

  @enforce_keys [:spec_id]
  defstruct [:spec_id]

  # Numeric ordinals for hardfork comparison. Higher = newer.
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
    prague: 12,
    osaka: 13
  }

  # Maps each EIP feature flag to the first hardfork that activates it.
  @eip_activation %{
    # EIP-2 (Homestead): contract-creation transactions cost 32,000 more
    eip_2: :homestead,
    # EIP-7 (Homestead): DELEGATECALL opcode
    eip_7: :homestead,
    # EIP-150 (Tangerine Whistle): IO-heavy opcode repricing
    eip_150: :tangerine_whistle,
    # EIP-160 (Spurious Dragon): EXP costs 50 gas per exponent byte instead of 10
    eip_160: :spurious_dragon,
    # EIP-161 (Spurious Dragon): empty-account clearing
    eip_161: :spurious_dragon,
    # EIP-170 (Spurious Dragon): 24,576-byte runtime code size limit
    eip_170: :spurious_dragon,
    # EIP-196 (Byzantium): alt_bn128 ADD and MUL precompiles at 0x06 and 0x07
    eip_196: :byzantium,
    # EIP-197 (Byzantium): alt_bn128 pairing precompile at 0x08
    eip_197: :byzantium,
    # EIP-198 (Byzantium): ModExp precompile at 0x05
    eip_198: :byzantium,
    # EIP-140 (Byzantium): REVERT opcode
    eip_140: :byzantium,
    # EIP-211 (Byzantium): RETURNDATASIZE and RETURNDATACOPY opcodes
    eip_211: :byzantium,
    # EIP-214 (Byzantium): STATICCALL opcode
    eip_214: :byzantium,
    # EIP-145 (Constantinople): SHL, SHR and SAR opcodes
    eip_145: :constantinople,
    # EIP-1052 (Constantinople): EXTCODEHASH opcode
    eip_1052: :constantinople,
    # EIP-1014 (Constantinople): CREATE2 opcode
    eip_1014: :constantinople,
    # EIP-2200 (Istanbul): structured SSTORE net metering
    eip_2200: :istanbul,
    # EIP-1344 (Istanbul): CHAINID opcode
    eip_1344: :istanbul,
    # EIP-1884 (Istanbul): SELFBALANCE opcode; BALANCE, SLOAD, EXTCODEHASH repricing
    eip_1884: :istanbul,
    # EIP-2028 (Istanbul): non-zero calldata bytes cost 16 gas instead of 68
    eip_2028: :istanbul,
    # EIP-152 (Istanbul): BLAKE2F precompile at 0x09
    eip_152: :istanbul,
    # EIP-1108 (Istanbul): cheaper alt_bn128 precompiles
    eip_1108: :istanbul,
    # EIP-2929 (Berlin): cold/warm address & storage access costs
    eip_2929: :berlin,
    # EIP-2565 (Berlin): ModExp repricing
    eip_2565: :berlin,
    # EIP-1559 (London): fee market; header base_fee_per_gas follows the parent's gas usage
    eip_1559: :london,
    # EIP-3529 (London): reduce gas refunds (cap at 1/5 of gas used)
    eip_3529: :london,
    # EIP-3198 (London): BASEFEE opcode
    eip_3198: :london,
    # EIP-3541 (London): reject runtime code with 0xEF prefix (EOF reserved)
    eip_3541: :london,
    # EIP-3675 (Paris): proof of stake; difficulty, nonce, and ommers are fixed to empty values
    eip_3675: :paris,
    # EIP-4895 (Shanghai): beacon-chain withdrawals; header withdrawals_root
    eip_4895: :shanghai,
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
    # EIP-7516 (Cancun): BLOBBASEFEE opcode
    eip_7516: :cancun,
    # EIP-6780 (Cancun): SELFDESTRUCT only deletes if created this tx
    eip_6780: :cancun,
    # EIP-4788 (Cancun): parent beacon block root system contract at 0x000F3df6...Beac02
    eip_4788: :cancun,
    # EIP-2537 (Prague): BLS12-381 precompiles at 0x0B-0x11
    eip_2537: :prague,
    # EIP-7623 (Prague): calldata floor pricing
    eip_7623: :prague,
    # EIP-2935 (Prague): historical block hashes system contract at 0x0000F908...2935
    eip_2935: :prague,
    # EIP-7691 (Prague): blob schedule raised to target 6 / max 9 blobs per block
    eip_7691: :prague,
    # EIP-7685 (Prague): general execution-layer requests; header requests_hash
    eip_7685: :prague,
    # EIP-6110 (Prague): deposit requests from the deposit contract's logs
    eip_6110: :prague,
    # EIP-7002 (Prague): withdrawal requests from the system contract at 0x00000961...7002
    eip_7002: :prague,
    # EIP-7251 (Prague): consolidation requests from the system contract at 0x0000BBdD...7251
    eip_7251: :prague,
    # EIP-7702 (Prague): set-code transactions and delegation designators
    eip_7702: :prague,
    # EIP-7825 (Osaka): per-transaction gas limit cap of 2^24
    eip_7825: :osaka,
    # EIP-7823 (Osaka): ModExp base, exponent, and modulus lengths capped at 1024 bytes
    eip_7823: :osaka,
    # EIP-7883 (Osaka): ModExp precompile gas cost increase
    eip_7883: :osaka,
    # EIP-7918 (Osaka): blob base fee bounded below by execution cost
    eip_7918: :osaka,
    # EIP-7934 (Osaka): RLP-encoded execution block capped at 8 MiB (10 MiB minus 2 MiB margin)
    eip_7934: :osaka,
    # EIP-7939 (Osaka/Fusaka): CLZ opcode
    eip_7939: :osaka,
    # EIP-7951 (Osaka): P256VERIFY (secp256r1) precompile at 0x100
    eip_7951: :osaka
  }

  @doc """
  Creates a new hardfork config for the given `spec_id`.

  ## Example

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

  @doc """
  Returns the default hardfork config — Cancun, the most-tested hardfork.

  Callers that don't specify a hardfork explicitly get Cancun semantics,
  preserving backwards compatibility with all existing tests.
  """
  @spec default() :: t()
  def default, do: new(:cancun)

  @doc """
  Returns a list of all known spec IDs in chronological order.
  """
  @spec all_spec_ids() :: [spec_id()]
  def all_spec_ids do
    @spec_order
    |> Enum.sort_by(fn {_k, v} -> v end)
    |> Enum.map(fn {k, _v} -> k end)
  end
end
