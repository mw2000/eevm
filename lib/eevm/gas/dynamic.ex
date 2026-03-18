defmodule EEVM.Gas.Dynamic do
  @moduledoc """
  Dynamic gas costs that depend on opcode operands at runtime.

  Unlike static costs (which are fixed per opcode), dynamic costs vary based on
  the actual values being operated on — the size of data being hashed, the number
  of log topics, the storage slot transition, etc.

  ## Covered Opcodes

  | Opcode | Dynamic Cost | Reference |
  |--------|-------------|-----------|
  | EXP | 50 × byte_size(exponent) | Yellow Paper |
  | KECCAK256 | 6 × word_count(size) | Yellow Paper |
  | CALLDATACOPY, CODECOPY, RETURNDATACOPY | 3 × word_count(size) | Yellow Paper |
  | LOG0–LOG4 | 375 + 375 × topics + 8 × data_size | Yellow Paper |
  | CREATE2 | 6 × word_count(initcode_size) | EIP-1014 |
  | CREATE/CREATE2 deploy | 200 × code_size | Yellow Paper |
  | CALL value transfer | 9,000 gas | Yellow Paper |
  | CALL new account creation | 25,000 gas | Yellow Paper |
  | CALL gas forwarding | min(requested, available - available/64) | EIP-150 |
  | CALL value stipend | 2,300 gas | Yellow Paper |
  | SSTORE | EIP-2200 schedule with EIP-3529 refund limits | EIP-2200, EIP-3529 |

  ## References

  - [Ethereum Yellow Paper, Appendix H](https://ethereum.github.io/yellowpaper/paper.pdf)
  - [EIP-150: Gas cost changes for IO-heavy operations](https://eips.ethereum.org/EIPS/eip-150)
  - [EIP-1014: Skinny CREATE2](https://eips.ethereum.org/EIPS/eip-1014)
  - [EIP-2200: Structured Definitions for Net Gas Metering](https://eips.ethereum.org/EIPS/eip-2200)
  - [EIP-3529: Reduction in refunds](https://eips.ethereum.org/EIPS/eip-3529)
  """

  import Bitwise

  # EXP: 50 gas per byte of exponent (Yellow Paper)
  @gas_exp_byte 50
  # KECCAK256: 6 gas per 32-byte word of input (Yellow Paper)
  @gas_keccak256_word 6
  # CALLDATACOPY/CODECOPY/RETURNDATACOPY: 3 gas per 32-byte word (Yellow Paper)
  @gas_copy 3
  # LOG: base cost per LOG opcode (Yellow Paper)
  @gas_log 375
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
  # SSTORE: cost for setting a fresh slot (0 → non-zero) (EIP-2200)
  @sstore_set_gas 20_000
  # SSTORE: cost for resetting an existing slot (non-zero → non-zero) (EIP-2200)
  @sstore_reset_gas 2_900
  # SSTORE: refund for clearing a slot (non-zero → 0) (EIP-3529)
  @sstore_clears_schedule 4_800
  # SSTORE: cost for no-op writes (value unchanged) (EIP-2200)
  @sstore_noop_gas 100

  @spec exp_dynamic_cost(non_neg_integer()) :: non_neg_integer()
  def exp_dynamic_cost(0), do: 0

  def exp_dynamic_cost(exponent) do
    @gas_exp_byte * byte_size_of(exponent)
  end

  @spec keccak256_dynamic_cost(non_neg_integer()) :: non_neg_integer()
  def keccak256_dynamic_cost(size), do: @gas_keccak256_word * word_count(size)

  @spec copy_cost(non_neg_integer()) :: non_neg_integer()
  def copy_cost(size), do: div(size + 31, 32) * @gas_copy

  @spec log_cost(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def log_cost(topic_count, data_size),
    do: @gas_log + @gas_log_topic * topic_count + @gas_log_data * data_size

  @spec create2_hash_cost(non_neg_integer()) :: non_neg_integer()
  def create2_hash_cost(init_code_size), do: word_count(init_code_size) * @gas_create2_word

  @spec code_deposit_cost(non_neg_integer()) :: non_neg_integer()
  def code_deposit_cost(code_size), do: code_size * @gas_code_deposit

  @spec call_value_cost(non_neg_integer()) :: non_neg_integer()
  def call_value_cost(0), do: 0
  def call_value_cost(_value), do: @gas_call_value

  @spec call_new_account_cost(boolean(), non_neg_integer()) :: non_neg_integer()
  def call_new_account_cost(_exists?, 0), do: 0
  def call_new_account_cost(true, _value), do: 0
  def call_new_account_cost(false, _value), do: @gas_new_account

  @spec call_forwarded_gas(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def call_forwarded_gas(available_gas, requested_gas) do
    max_forward = available_gas - div(available_gas, 64)
    min(requested_gas, max_forward)
  end

  @spec call_stipend(non_neg_integer()) :: non_neg_integer()
  def call_stipend(0), do: 0
  def call_stipend(_value), do: 2300

  @spec sstore_cost(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), integer()}
  def sstore_cost(original, current, new_value) do
    cond do
      current == new_value ->
        {@sstore_noop_gas, 0}

      original == current and original == 0 ->
        {@sstore_set_gas, 0}

      original == current ->
        refund = if new_value == 0, do: @sstore_clears_schedule, else: 0
        {@sstore_reset_gas, refund}

      true ->
        refund = dirty_slot_refund_delta(original, current, new_value)
        {@sstore_noop_gas, refund}
    end
  end

  @spec sstore_cost(non_neg_integer(), non_neg_integer(), non_neg_integer(), boolean()) ::
          {non_neg_integer(), integer()}
  def sstore_cost(original, current, new_value, _is_warm),
    do: sstore_cost(original, current, new_value)

  defp dirty_slot_refund_delta(original, current, new_value) do
    base_refund =
      if original != 0 do
        0
        |> maybe_subtract(current == 0, @sstore_clears_schedule)
        |> maybe_add(new_value == 0, @sstore_clears_schedule)
      else
        0
      end

    if original == new_value do
      if original == 0,
        do: base_refund + (@sstore_set_gas - @sstore_noop_gas),
        else: base_refund + (@sstore_reset_gas - @sstore_noop_gas)
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
