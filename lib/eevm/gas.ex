defmodule EEVM.Gas do
  @moduledoc """
  Gas costs for EVM opcodes and memory expansion.

  ## EVM Concepts

  Gas is the EVM's metering mechanism — every instruction costs a fixed amount
  of gas, and some instructions have additional "dynamic" gas costs that depend
  on their operands. If execution runs out of gas, the transaction reverts.

  Gas serves two purposes:
  1. **DoS prevention** — prevents infinite loops and resource abuse
  2. **Fee market** — users pay for computation proportional to its cost

  ## Gas Categories

  - **Static gas**: Fixed cost per opcode (e.g., ADD = 3, MUL = 5)
  - **Dynamic gas**: Variable cost based on operands (e.g., EXP costs 50 per
    byte of exponent, KECCAK256 costs 6 per 32-byte word of input)
  - **Memory expansion gas**: Quadratic cost when memory grows beyond its
    current allocation

  ## Elixir Learning Notes

  - This module is purely functional — no state, just cost calculations
  - We use `div/2` for integer division (Elixir's `/` returns floats!)
  - Pattern matching on opcode bytes dispatches to the right cost
  - The `@gas_*` module attributes group related constants
  """

  import Bitwise

  # --- Base gas costs (Appendix G of the Yellow Paper) ---

  @gas_zero 0
  @gas_base 2
  @gas_very_low 3
  @gas_low 5
  @gas_mid 8
  @gas_high 10
  @gas_jumpdest 1

  # Dynamic gas constants
  @gas_exp_byte 50
  @gas_keccak256 30
  @gas_keccak256_word 6
  @gas_memory 3
  @gas_sload 200
  @gas_sstore 20_000

  @doc """
  Returns the static gas cost for a given opcode byte.

  Some opcodes also have dynamic costs — see `dynamic_cost/2`.

  ## Gas Cost Table (Shanghai)

  | Cost | Opcodes |
  |------|---------|
  | 0    | STOP, RETURN, REVERT |
  | 2    | ADDRESS, ORIGIN, CALLER, CALLVALUE, CALLDATASIZE, CODESIZE, GASPRICE, COINBASE, TIMESTAMP, NUMBER, PREVRANDAO, GASLIMIT, CHAINID, SELFBALANCE, BASEFEE, POP, PC, MSIZE, GAS |
  | 3    | ADD, SUB, NOT, LT, GT, SLT, SGT, EQ, ISZERO, AND, OR, XOR, BYTE, SHL, SHR, SAR, CALLDATALOAD, MLOAD, MSTORE, MSTORE8, PUSH*, DUP*, SWAP* |
  | 5    | MUL, DIV, SDIV, MOD, SMOD, SIGNEXTEND |
  | 8    | ADDMOD, MULMOD, JUMP |
  | 10   | JUMPI, EXP (+ dynamic) |
  | 1    | JUMPDEST |
  """
  @spec static_cost(non_neg_integer()) :: non_neg_integer()

  # 0x00: STOP
  def static_cost(0x00), do: @gas_zero

  # Arithmetic (0x01–0x0B)
  # ADD
  def static_cost(0x01), do: @gas_very_low
  # MUL
  def static_cost(0x02), do: @gas_low
  # SUB
  def static_cost(0x03), do: @gas_very_low
  # DIV
  def static_cost(0x04), do: @gas_low
  # SDIV
  def static_cost(0x05), do: @gas_low
  # MOD
  def static_cost(0x06), do: @gas_low
  # SMOD
  def static_cost(0x07), do: @gas_low
  # ADDMOD
  def static_cost(0x08), do: @gas_mid
  # MULMOD
  def static_cost(0x09), do: @gas_mid
  # EXP (+ dynamic)
  def static_cost(0x0A), do: @gas_high
  # SIGNEXTEND
  def static_cost(0x0B), do: @gas_low

  # Comparison & Bitwise Logic (0x10–0x1D)
  # LT
  def static_cost(0x10), do: @gas_very_low
  # GT
  def static_cost(0x11), do: @gas_very_low
  # SLT
  def static_cost(0x12), do: @gas_very_low
  # SGT
  def static_cost(0x13), do: @gas_very_low
  # EQ
  def static_cost(0x14), do: @gas_very_low
  # ISZERO
  def static_cost(0x15), do: @gas_very_low
  # AND
  def static_cost(0x16), do: @gas_very_low
  # OR
  def static_cost(0x17), do: @gas_very_low
  # XOR
  def static_cost(0x18), do: @gas_very_low
  # NOT
  def static_cost(0x19), do: @gas_very_low
  # BYTE
  def static_cost(0x1A), do: @gas_very_low
  # SHL
  def static_cost(0x1B), do: @gas_very_low
  # SHR
  def static_cost(0x1C), do: @gas_very_low
  # SAR
  def static_cost(0x1D), do: @gas_very_low

  # KECCAK256 (0x20) — static + dynamic per word
  def static_cost(0x20), do: @gas_keccak256

  # Stack, Memory, Control Flow (0x50–0x5B)
  # POP
  def static_cost(0x50), do: @gas_base
  # MLOAD (+ memory expansion)
  def static_cost(0x51), do: @gas_very_low
  # MSTORE (+ memory expansion)
  def static_cost(0x52), do: @gas_very_low
  # MSTORE8 (+ memory expansion)
  def static_cost(0x53), do: @gas_very_low
  # JUMP
  def static_cost(0x56), do: @gas_mid
  # JUMPI
  def static_cost(0x57), do: @gas_high
  # PC
  def static_cost(0x58), do: @gas_base
  # MSIZE
  def static_cost(0x59), do: @gas_base
  # JUMPDEST
  def static_cost(0x5B), do: @gas_jumpdest

  # Storage (0x54–0x55)
  # SLOAD
  def static_cost(0x54), do: @gas_sload
  # SSTORE
  def static_cost(0x55), do: @gas_sstore

  # PUSH1–PUSH32 (0x60–0x7F)
  def static_cost(op) when op >= 0x60 and op <= 0x7F, do: @gas_very_low

  # DUP1–DUP16 (0x80–0x8F)
  def static_cost(op) when op >= 0x80 and op <= 0x8F, do: @gas_very_low

  # SWAP1–SWAP16 (0x90–0x9F)
  def static_cost(op) when op >= 0x90 and op <= 0x9F, do: @gas_very_low

  # System (0xF3, 0xFD, 0xFE)
  # RETURN (+ memory expansion)
  def static_cost(0xF3), do: @gas_zero
  # REVERT (+ memory expansion)
  def static_cost(0xFD), do: @gas_zero
  # INVALID (consumes ALL remaining gas)
  def static_cost(0xFE), do: @gas_zero

  # Unknown opcodes — treated as INVALID
  def static_cost(_), do: @gas_zero

  @doc """
  Calculates the dynamic gas cost for EXP based on the exponent value.

  EXP costs 50 gas per byte of the exponent. An exponent of 0 has no dynamic
  cost, an exponent of 255 (1 byte) costs 50, an exponent of 256 (2 bytes)
  costs 100, etc.

  The number of bytes is `floor(log256(exponent)) + 1` for exponent > 0.
  """
  @spec exp_dynamic_cost(non_neg_integer()) :: non_neg_integer()
  def exp_dynamic_cost(0), do: 0

  def exp_dynamic_cost(exponent) do
    byte_size = byte_size_of(exponent)
    @gas_exp_byte * byte_size
  end

  @doc """
  Calculates the dynamic gas cost for KECCAK256 based on input size.

  Costs 6 gas per 32-byte word (rounded up) of input data.
  """
  @spec keccak256_dynamic_cost(non_neg_integer()) :: non_neg_integer()
  def keccak256_dynamic_cost(size) do
    words = word_count(size)
    @gas_keccak256_word * words
  end

  @doc """
  Calculates the gas cost of memory expansion.

  Memory costs are quadratic — growing memory gets progressively more expensive.
  This prevents contracts from using unbounded memory.

  The formula (from the Yellow Paper, Appendix H):

      memory_cost(word_count) = 3 * word_count + word_count² / 512

  The *expansion cost* is the difference between the new and old memory costs:

      expansion_gas = memory_cost(new_words) - memory_cost(old_words)

  A "word" is 32 bytes. If memory is already large enough, expansion cost is 0.

  ## Parameters

  - `current_size` — current memory size in bytes (always a multiple of 32)
  - `offset` — byte offset being accessed
  - `length` — number of bytes being accessed (0 means no expansion)
  """
  @spec memory_expansion_cost(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def memory_expansion_cost(_current_size, _offset, 0), do: 0

  def memory_expansion_cost(current_size, offset, length) do
    needed = offset + length
    new_size = word_ceil(needed) * 32

    if new_size <= current_size do
      0
    else
      old_words = div(current_size, 32)
      new_words = div(new_size, 32)
      memory_cost(new_words) - memory_cost(old_words)
    end
  end

  @doc """
  Calculates the gas cost of expanding memory for a 32-byte word access.

  Convenience wrapper for MLOAD/MSTORE which always access 32 bytes.
  """
  @spec memory_expansion_cost_word(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def memory_expansion_cost_word(current_size, offset) do
    memory_expansion_cost(current_size, offset, 32)
  end

  @doc """
  Calculates the gas cost of expanding memory for a single byte access.

  Used by MSTORE8.
  """
  @spec memory_expansion_cost_byte(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def memory_expansion_cost_byte(current_size, offset) do
    memory_expansion_cost(current_size, offset, 1)
  end

  # --- Private Helpers ---

  # Memory cost function: 3 * words + words² / 512
  # This is the absolute cost for a given memory size, NOT the expansion cost.
  defp memory_cost(word_count) do
    @gas_memory * word_count + div(word_count * word_count, 512)
  end

  # Rounds up to the nearest 32-byte word boundary.
  # e.g., 1 → 1, 32 → 1, 33 → 2, 64 → 2, 65 → 3
  defp word_count(0), do: 0

  defp word_count(byte_size) do
    div(byte_size + 31, 32)
  end

  # Same as word_count but for ceiling division of byte sizes.
  defp word_ceil(0), do: 0

  defp word_ceil(byte_size) do
    div(byte_size + 31, 32)
  end

  # Returns the number of bytes needed to represent an integer.
  # e.g., 0xFF → 1, 0x100 → 2, 0xFFFF → 2, 0x10000 → 3
  defp byte_size_of(0), do: 0

  defp byte_size_of(n) when n > 0 do
    div(floor_log256(n), 1) + 1
  end

  # Floor of log base 256 (i.e., how many full bytes minus one).
  # Equivalent to (bit_length - 1) / 8
  defp floor_log256(n) when n > 0 do
    bit_length = do_bit_length(n, 0)
    div(bit_length - 1, 8)
  end

  defp do_bit_length(0, acc), do: acc
  defp do_bit_length(n, acc), do: do_bit_length(n >>> 1, acc + 1)
end
