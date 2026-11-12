defmodule EEVM.Config do
  @moduledoc """
  Runtime configuration for EEVM execution: the hardfork whose rules apply,
  the chain id, any custom precompiles, and the simulation switches.

  Every entry point takes a config as its `:config` option, or the shorthand
  `:hardfork` (a fork atom) for a mainnet config of that fork.

  | Field | Description |
  |-------|-------------|
  | `hardfork` | The fork's rules; `config.hardfork.spec_id` is the fork atom, such as `:prague`. Ask `enabled?/2` whether a rule applies |
  | `chain_id` | The chain id, for EIP-155 signatures, EIP-7702 authorizations, and CHAINID |
  | `precompiles` | Custom precompiles by address, added with `register_precompile/3` |
  | `disable_nonce_check` | Simulation only: accept any transaction nonce. The sender's nonce is still incremented |
  | `disable_balance_check` | Simulation only: accept a sender that can't afford the gas and value |
  | `disable_base_fee` | Simulation only: accept a fee cap or gas price below the block's base fee |
  | `disable_block_gas_limit` | Simulation only: accept a transaction gas limit above the block's |
  | `disable_eip3607` | Simulation only: accept a sender that has code (EIP-3607) |

  ## Example

      iex> config = EEVM.Config.new(:prague, chain_id: 11_155_111)
      iex> config.chain_id
      11155111
      iex> EEVM.Config.enabled?(config, :eip_7702)
      true
      iex> EEVM.Config.enabled?(config, :eip_7939)
      false

  ## Simulation switches

  The `disable_*` fields relax `EEVM.transact/4`'s validity rules for
  tooling that simulates transactions, such as `eth_call`-style RPC, gas
  estimation, and fork tests. They mirror revm's `CfgEnv` switches of the
  same names, and all default to `false`. **They are for simulation and must
  never be set when validating or building real blocks**: with any of them
  on, eevm accepts transactions that no Ethereum node would.

  - `disable_nonce_check` skips the nonce comparison (and EIP-2681's limit),
    but still increments the sender's nonce, and a creation's address still
    comes from the account's nonce.
  - `disable_balance_check` skips the upfront balance check. The sender's
    balance is first raised to at least the transaction's `value`, then
    charged for gas as far as it can pay while keeping `value`; unused gas is
    refunded as usual, so a sender that could not afford the fee may end
    with more than it started with.
  - `disable_base_fee` accepts a `max_fee_per_gas` (or legacy `gas_price`)
    below the block's base fee. The sender then pays its fee cap per gas,
    and the coinbase earns no tip.
  - `disable_block_gas_limit` lets a transaction's gas limit exceed the
    block's. The EIP-7825 cap from Osaka still applies.
  - `disable_eip3607` lets a sender with code, such as a contract or a
    multisig, send a transaction.

  Together with an unsigned `EEVM.TxEnv`, which `EEVM.transact/4` accepts
  in place of a signed transaction, they let a tool run a transaction from
  any address:

      iex> config = EEVM.Config.new(:cancun, disable_nonce_check: true, disable_balance_check: true)
      iex> tx = %EEVM.TxEnv{origin: 0xDEAD, nonce: 7, to: 0xB0B, value: 5, gas_limit: 21_000, gas_price: 1}
      iex> {:ok, result} = EEVM.transact(tx, EEVM.BlockEnv.new(), EEVM.Database.InMemory.new(), config: config)
      iex> {result.status, EEVM.Database.get_balance(result.db, 0xB0B), EEVM.Database.get_nonce(result.db, 0xDEAD)}
      {:success, 5, 1}
  """

  alias EEVM.HardforkConfig

  @type t :: %__MODULE__{
          hardfork: HardforkConfig.t(),
          chain_id: non_neg_integer(),
          precompiles: %{optional(non_neg_integer()) => module()},
          disable_nonce_check: boolean(),
          disable_balance_check: boolean(),
          disable_base_fee: boolean(),
          disable_block_gas_limit: boolean(),
          disable_eip3607: boolean()
        }

  @switches [
    disable_nonce_check: false,
    disable_balance_check: false,
    disable_base_fee: false,
    disable_block_gas_limit: false,
    disable_eip3607: false
  ]

  defstruct [:hardfork, chain_id: 1, precompiles: %{}] ++ @switches

  @typedoc "An option of `new/2`."
  @type option ::
          {:chain_id, non_neg_integer()}
          | {:disable_nonce_check, boolean()}
          | {:disable_balance_check, boolean()}
          | {:disable_base_fee, boolean()}
          | {:disable_block_gas_limit, boolean()}
          | {:disable_eip3607, boolean()}

  @doc """
  Creates a config for `hardfork` (default `:cancun`).

  Options: `:chain_id` (default `1`, mainnet), used for EIP-155 signatures,
  EIP-7702 authorizations, and the CHAINID opcode, and the simulation
  switches `:disable_nonce_check`, `:disable_balance_check`,
  `:disable_base_fee`, `:disable_block_gas_limit`, and `:disable_eip3607`
  (each default `false`; see "Simulation switches" above, and never set
  them for consensus). Any other option raises `ArgumentError`.

  ## Examples

      iex> config = EEVM.Config.new()
      iex> {config.hardfork.spec_id, config.chain_id, config.disable_nonce_check}
      {:cancun, 1, false}

      iex> config = EEVM.Config.new(:berlin, chain_id: 5, disable_eip3607: true)
      iex> {config.hardfork.spec_id, config.chain_id, config.disable_eip3607}
      {:berlin, 5, true}
  """
  @spec new(HardforkConfig.spec_id(), [option()]) :: t()
  def new(hardfork \\ :cancun, opts \\ []) do
    opts = Keyword.validate!(opts, [chain_id: 1] ++ @switches)
    struct!(__MODULE__, [hardfork: HardforkConfig.new(hardfork)] ++ opts)
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
