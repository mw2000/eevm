defmodule EEVM.Gas.Dynamic do
  @moduledoc """
  Dynamic gas costs that depend on opcode operands at runtime.

  Unlike static costs (which are fixed per opcode), dynamic costs vary based on
  the actual values being operated on — the size of data being hashed, the number
  of log topics, the storage slot transition, etc.

  ## Covered Opcodes

  | Opcode | Dynamic Cost | Reference |
  |--------|-------------|-----------|
  | EXP | 50 × byte_size(exponent); 10 before Spurious Dragon | EIP-160 |
  | KECCAK256 | 6 × word_count(size) | Yellow Paper |
  | CALLDATACOPY, CODECOPY, RETURNDATACOPY | 3 × word_count(size) | Yellow Paper |
  | LOG0–LOG4 | 375 × topics + 8 × data_size (the 375 base is static) | Yellow Paper |
  | CREATE2 | 6 × word_count(initcode_size) | EIP-1014 |
  | CREATE/CREATE2 deploy | 200 × code_size | Yellow Paper |
  | CALL value transfer | 9,000 gas | Yellow Paper |
  | CALL, SELFDESTRUCT new account creation | 25,000 gas | Yellow Paper, EIP-150, EIP-161 |
  | CALL gas forwarding | min(requested, available - available/64); requested before Tangerine Whistle | EIP-150 |
  | CALL value stipend | 2,300 gas | Yellow Paper |
  | SSTORE | per-fork schedule, see `sstore_cost/4` | EIP-2200, EIP-2929, EIP-3529 |

  ## References

  - [Ethereum Yellow Paper, Appendix H](https://ethereum.github.io/yellowpaper/paper.pdf)
  - [EIP-150: Gas cost changes for IO-heavy operations](https://eips.ethereum.org/EIPS/eip-150)
  - [EIP-1014: Skinny CREATE2](https://eips.ethereum.org/EIPS/eip-1014)
  - [EIP-2200: Structured Definitions for Net Gas Metering](https://eips.ethereum.org/EIPS/eip-2200)
  - [EIP-2929: Gas cost increases for state access opcodes](https://eips.ethereum.org/EIPS/eip-2929)
  - [EIP-3529: Reduction in refunds](https://eips.ethereum.org/EIPS/eip-3529)
  """

  import Bitwise

  alias EEVM.HardforkConfig

  # EXP: gas per byte of exponent, raised from 10 to 50 by EIP-160
  @gas_exp_byte 50
  @frontier_gas_exp_byte 10
  # KECCAK256: 6 gas per 32-byte word of input (Yellow Paper)
  @gas_keccak256_word 6
  # CALLDATACOPY/CODECOPY/RETURNDATACOPY: 3 gas per 32-byte word (Yellow Paper)
  @gas_copy 3
  # LOG: additional cost per topic (Yellow Paper)
  @gas_log_topic 375
  # LOG: cost per byte of data (Yellow Paper)
  @gas_log_data 8
  # CREATE2: 6 gas per 32-byte word of initcode for hashing (EIP-1014)
  @gas_create2_word 6
  # Code deposit: 200 gas per byte of deployed runtime code (Yellow Paper)
  @gas_code_deposit 200
  # CALL: extra cost when transferring non-zero value (Yellow Paper)
  @gas_call_value 9000
  # CALL: extra cost when creating a new account via value transfer (Yellow Paper)
  @gas_new_account 25_000
  # SSTORE: cost for setting a fresh slot (0 → non-zero), every fork
  @sstore_set_gas 20_000
  # SSTORE: cost for any other write before EIP-2929 (Yellow Paper, EIP-2200)
  @sstore_reset_gas 5_000
  # SSTORE: refund for clearing a slot (non-zero → 0) before EIP-3529
  @sstore_clears_schedule 15_000
  # EIP-2200: no-op and dirty writes cost SLOAD_GAS, 800 since EIP-1884
  @sload_gas 800
  # EIP-2929: SLOAD_GAS becomes the warm read cost, and the cold-slot charge
  # (2,100) moves out of SSTORE_RESET_GAS
  @warm_storage_read_cost 100
  @cold_sload_cost 2_100
  # EIP-3529: reduced refund for clearing a slot
  @eip_3529_sstore_clears_schedule 4_800

  @spec exp_dynamic_cost(non_neg_integer(), HardforkConfig.t()) :: non_neg_integer()
  def exp_dynamic_cost(0, _hardfork), do: 0

  def exp_dynamic_cost(exponent, hardfork) do
    byte_cost =
      if HardforkConfig.enabled?(hardfork, :eip_160),
        do: @gas_exp_byte,
        else: @frontier_gas_exp_byte

    byte_cost * byte_size_of(exponent)
  end

  @spec keccak256_dynamic_cost(non_neg_integer()) :: non_neg_integer()
  def keccak256_dynamic_cost(size), do: @gas_keccak256_word * word_count(size)

  @spec copy_cost(non_neg_integer()) :: non_neg_integer()
  def copy_cost(size), do: div(size + 31, 32) * @gas_copy

  @doc """
  Dynamic part of LOG0–LOG4: 375 per topic plus 8 per data byte. The 375
  base (G_log) is the opcode's static cost in `EEVM.Gas.Static`.
  """
  @spec log_cost(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def log_cost(topic_count, data_size),
    do: @gas_log_topic * topic_count + @gas_log_data * data_size

  @spec create2_hash_cost(non_neg_integer()) :: non_neg_integer()
  def create2_hash_cost(init_code_size), do: word_count(init_code_size) * @gas_create2_word

  @spec code_deposit_cost(non_neg_integer()) :: non_neg_integer()
  def code_deposit_cost(code_size), do: code_size * @gas_code_deposit

  @spec call_value_cost(non_neg_integer()) :: non_neg_integer()
  def call_value_cost(0), do: 0
  def call_value_cost(_value), do: @gas_call_value

  @doc """
  25,000 when a CALL brings an account into existence. From Spurious Dragon
  (EIP-161) that is a value transfer to an empty account; before, a call to
  any account that does not exist.
  """
  @spec call_new_account_cost(boolean(), boolean(), non_neg_integer(), HardforkConfig.t()) ::
          non_neg_integer()
  def call_new_account_cost(exists?, empty?, value, hardfork) do
    creates_account? =
      if HardforkConfig.enabled?(hardfork, :eip_161),
        do: value > 0 and empty?,
        else: not exists?

    if creates_account?, do: @gas_new_account, else: 0
  end

  @doc """
  25,000 when SELFDESTRUCT brings its beneficiary into existence: from
  Tangerine Whistle (EIP-150) when the beneficiary does not exist, and from
  Spurious Dragon (EIP-161) only when a non-zero balance moves to an empty
  account. Nothing before Tangerine Whistle.
  """
  @spec selfdestruct_new_account_cost(
          boolean(),
          boolean(),
          non_neg_integer(),
          HardforkConfig.t()
        ) :: non_neg_integer()
  def selfdestruct_new_account_cost(exists?, empty?, balance, hardfork) do
    creates_account? =
      cond do
        HardforkConfig.enabled?(hardfork, :eip_161) -> balance > 0 and empty?
        HardforkConfig.enabled?(hardfork, :eip_150) -> not exists?
        true -> false
      end

    if creates_account?, do: @gas_new_account, else: 0
  end

  @doc """
  Gas a CALL-family or CREATE opcode hands to its child frame. From Tangerine
  Whistle (EIP-150) the caller keeps 1/64 of what it has left and the request
  is capped at the rest; before, the full request is forwarded, and a request
  above the available gas is an out-of-gas error in the caller.
  """
  @spec call_forwarded_gas(non_neg_integer(), non_neg_integer(), HardforkConfig.t()) ::
          non_neg_integer()
  def call_forwarded_gas(available_gas, requested_gas, hardfork) do
    if HardforkConfig.enabled?(hardfork, :eip_150) do
      max_forward = available_gas - div(available_gas, 64)
      min(requested_gas, max_forward)
    else
      requested_gas
    end
  end

  @spec call_stipend(non_neg_integer()) :: non_neg_integer()
  def call_stipend(0), do: 0
  def call_stipend(_value), do: 2300

  @doc """
  Returns `{gas, refund_delta}` for an SSTORE writing `new_value` over
  `current`, where `original` is the slot's value at the start of the
  transaction. The cold-slot charge (EIP-2929) is separate, in
  `EEVM.Gas.Access.sstore_access_cost/3`.

  - Before Istanbul: 20,000 to set a zero slot, 5,000 for any other write,
    and a 15,000 refund for clearing one.
  - Istanbul (EIP-2200) net metering: writes that leave the slot unchanged
    or touch an already-dirty slot cost SLOAD_GAS (800); refunds track
    whether the write clears the slot or restores its original value.
  - Berlin (EIP-2929): SLOAD_GAS becomes 100 and the 5,000 reset cost 2,900.
  - London (EIP-3529): the clearing refund drops to 4,800.

  ## Examples

      iex> EEVM.Gas.Dynamic.sstore_cost(7, 7, 0, EEVM.HardforkConfig.new(:byzantium))
      {5000, 15000}

      iex> EEVM.Gas.Dynamic.sstore_cost(7, 7, 0, EEVM.HardforkConfig.new(:istanbul))
      {5000, 15000}

      iex> EEVM.Gas.Dynamic.sstore_cost(7, 9, 9, EEVM.HardforkConfig.new(:istanbul))
      {800, 0}

      iex> EEVM.Gas.Dynamic.sstore_cost(7, 7, 0, EEVM.HardforkConfig.new(:london))
      {2900, 4800}
  """
  @spec sstore_cost(non_neg_integer(), non_neg_integer(), non_neg_integer(), HardforkConfig.t()) ::
          {non_neg_integer(), integer()}
  def sstore_cost(original, current, new_value, hardfork) do
    if HardforkConfig.enabled?(hardfork, :eip_2200) do
      net_metered_sstore_cost(original, current, new_value, sstore_schedule(hardfork))
    else
      legacy_sstore_cost(current, new_value)
    end
  end

  defp legacy_sstore_cost(0, new_value) when new_value != 0, do: {@sstore_set_gas, 0}

  defp legacy_sstore_cost(current, 0) when current != 0,
    do: {@sstore_reset_gas, @sstore_clears_schedule}

  defp legacy_sstore_cost(_current, _new_value), do: {@sstore_reset_gas, 0}

  # {SLOAD_GAS, SSTORE_RESET_GAS, SSTORE_CLEARS_SCHEDULE} for the fork.
  defp sstore_schedule(hardfork) do
    {sload_gas, reset_gas} =
      if HardforkConfig.enabled?(hardfork, :eip_2929),
        do: {@warm_storage_read_cost, @sstore_reset_gas - @cold_sload_cost},
        else: {@sload_gas, @sstore_reset_gas}

    clears_schedule =
      if HardforkConfig.enabled?(hardfork, :eip_3529),
        do: @eip_3529_sstore_clears_schedule,
        else: @sstore_clears_schedule

    {sload_gas, reset_gas, clears_schedule}
  end

  defp net_metered_sstore_cost(original, current, new_value, schedule) do
    {sload_gas, reset_gas, clears} = schedule

    cond do
      current == new_value ->
        {sload_gas, 0}

      original == current and original == 0 ->
        {@sstore_set_gas, 0}

      original == current ->
        refund = if new_value == 0, do: clears, else: 0
        {reset_gas, refund}

      true ->
        {sload_gas, dirty_slot_refund_delta(original, current, new_value, schedule)}
    end
  end

  defp dirty_slot_refund_delta(original, current, new_value, {sload_gas, reset_gas, clears}) do
    base_refund =
      if original != 0 do
        0
        |> maybe_subtract(current == 0, clears)
        |> maybe_add(new_value == 0, clears)
      else
        0
      end

    if original == new_value do
      if original == 0,
        do: base_refund + (@sstore_set_gas - sload_gas),
        else: base_refund + (reset_gas - sload_gas)
    else
      base_refund
    end
  end

  defp maybe_add(value, true, amount), do: value + amount
  defp maybe_add(value, false, _amount), do: value

  defp maybe_subtract(value, true, amount), do: value - amount
  defp maybe_subtract(value, false, _amount), do: value

  defp word_count(0), do: 0
  defp word_count(byte_size), do: div(byte_size + 31, 32)

  defp byte_size_of(0), do: 0
  defp byte_size_of(n) when n > 0, do: div(floor_log256(n), 1) + 1

  defp floor_log256(n) when n > 0 do
    bit_length = do_bit_length(n, 0)
    div(bit_length - 1, 8)
  end

  defp do_bit_length(0, acc), do: acc
  defp do_bit_length(n, acc), do: do_bit_length(n >>> 1, acc + 1)
end
