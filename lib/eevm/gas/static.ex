defmodule EEVM.Gas.Static do
  @moduledoc """
  Static gas costs for each EVM opcode.

  Every opcode has a fixed ("static") gas cost that is charged before execution,
  independent of the operand values. These costs come from the Ethereum Yellow Paper
  (Appendix G) and subsequent EIPs.

  ## Gas Tiers (Yellow Paper, Appendix G)

  | Tier       | Cost | Opcodes |
  |------------|------|---------|
  | Zero       | 0    | STOP, RETURN, REVERT |
  | Base       | 2    | ADDRESS, ORIGIN, CALLER, CALLVALUE, CALLDATASIZE, CODESIZE, GASPRICE, COINBASE, TIMESTAMP, NUMBER, PREVRANDAO, GASLIMIT, CHAINID, BASEFEE, POP, PC, MSIZE, PUSH0 |
  | Very Low   | 3    | ADD, SUB, NOT, LT, GT, SLT, SGT, EQ, ISZERO, AND, OR, XOR, BYTE, SHL, SHR, SAR, CALLDATALOAD, MLOAD, MSTORE, MSTORE8, PUSH1–PUSH32, DUP1–DUP16, SWAP1–SWAP16 |
  | Low        | 5    | MUL, DIV, SDIV, MOD, SMOD, SIGNEXTEND |
  | Mid        | 8    | ADDMOD, MULMOD, JUMP |
  | High       | 10   | JUMPI |

  Some opcodes have a static cost of 0 because their full cost is computed dynamically
  (e.g., BALANCE, EXTCODESIZE, SLOAD, SSTORE use EIP-2929 access costs instead).

  ## References

  - [Ethereum Yellow Paper, Appendix G](https://ethereum.github.io/yellowpaper/paper.pdf)
  - [EIP-2929: Gas cost increases for state access opcodes](https://eips.ethereum.org/EIPS/eip-2929)
  """

  # Yellow Paper Appendix G — gas cost tiers
  @gas_zero 0
  @gas_base 2
  @gas_very_low 3
  @gas_low 5
  @gas_mid 8
  @gas_high 10

  # Special per-opcode costs
  @gas_jumpdest 1
  @gas_keccak256 30
  @gas_blockhash 20
  # EIP-1884: SELFBALANCE at 5 gas (cheap self-balance read)
  @gas_selfbalance 5
  @gas_log 375
  # EIP-2929: warm storage read cost, used as base for CALL-family opcodes
  @gas_warm_access 100
  @gas_create 32_000
  @gas_selfdestruct 5000

  @doc """
  Returns the static gas cost for the given opcode byte.

  This cost is charged by the executor before dispatching to the opcode handler.
  Dynamic costs (memory expansion, storage access, etc.) are charged separately
  within each opcode's implementation.
  """
  @spec static_cost(non_neg_integer()) :: non_neg_integer()
  # 0x00: STOP
  def static_cost(0x00), do: @gas_zero

  # 0x01–0x0B: Arithmetic
  def static_cost(0x01), do: @gas_very_low
  def static_cost(0x02), do: @gas_low
  def static_cost(0x03), do: @gas_very_low
  def static_cost(0x04), do: @gas_low
  def static_cost(0x05), do: @gas_low
  def static_cost(0x06), do: @gas_low
  def static_cost(0x07), do: @gas_low
  def static_cost(0x08), do: @gas_mid
  def static_cost(0x09), do: @gas_mid
  def static_cost(0x0A), do: @gas_high
  def static_cost(0x0B), do: @gas_low

  # 0x10–0x1D: Comparison & Bitwise
  def static_cost(0x10), do: @gas_very_low
  def static_cost(0x11), do: @gas_very_low
  def static_cost(0x12), do: @gas_very_low
  def static_cost(0x13), do: @gas_very_low
  def static_cost(0x14), do: @gas_very_low
  def static_cost(0x15), do: @gas_very_low
  def static_cost(0x16), do: @gas_very_low
  def static_cost(0x17), do: @gas_very_low
  def static_cost(0x18), do: @gas_very_low
  def static_cost(0x19), do: @gas_very_low
  def static_cost(0x1A), do: @gas_very_low
  def static_cost(0x1B), do: @gas_very_low
  def static_cost(0x1C), do: @gas_very_low
  def static_cost(0x1D), do: @gas_very_low

  # 0x20: KECCAK256 (static base; dynamic cost added per word in Gas.Dynamic)
  def static_cost(0x20), do: @gas_keccak256

  # 0x30–0x4A: Environment & Block Information
  def static_cost(0x30), do: @gas_base
  # BALANCE: static=0, full cost via EIP-2929 cold/warm access
  def static_cost(0x31), do: 0
  def static_cost(0x32), do: @gas_base
  def static_cost(0x33), do: @gas_base
  def static_cost(0x34), do: @gas_base
  def static_cost(0x35), do: @gas_very_low
  def static_cost(0x36), do: @gas_base
  def static_cost(0x37), do: @gas_very_low
  def static_cost(0x38), do: @gas_base
  def static_cost(0x39), do: @gas_very_low
  def static_cost(0x3A), do: @gas_base
  # EXTCODESIZE: static=0, full cost via EIP-2929
  def static_cost(0x3B), do: 0
  # EXTCODECOPY: static=0, full cost via EIP-2929 + copy cost
  def static_cost(0x3C), do: 0
  def static_cost(0x3D), do: @gas_base
  def static_cost(0x3E), do: @gas_very_low
  # EXTCODEHASH: static=0, full cost via EIP-2929
  def static_cost(0x3F), do: 0
  def static_cost(0x40), do: @gas_blockhash
  def static_cost(0x41), do: @gas_base
  def static_cost(0x42), do: @gas_base
  def static_cost(0x43), do: @gas_base
  def static_cost(0x44), do: @gas_base
  def static_cost(0x45), do: @gas_base
  def static_cost(0x46), do: @gas_base
  # EIP-1884: SELFBALANCE
  def static_cost(0x47), do: @gas_selfbalance
  def static_cost(0x48), do: @gas_base
  def static_cost(0x49), do: @gas_very_low
  def static_cost(0x4A), do: @gas_base

  # 0x50–0x5F: Stack, Memory, Storage & Flow
  def static_cost(0x50), do: @gas_base
  def static_cost(0x51), do: @gas_very_low
  def static_cost(0x52), do: @gas_very_low
  def static_cost(0x53), do: @gas_very_low
  # SLOAD: static=0, full cost via EIP-2929 cold/warm access
  def static_cost(0x54), do: 0
  # SSTORE: static=0, full cost via EIP-2200 + EIP-2929 schedule
  def static_cost(0x55), do: 0
  def static_cost(0x56), do: @gas_mid
  def static_cost(0x57), do: @gas_high
  def static_cost(0x58), do: @gas_base
  def static_cost(0x59), do: @gas_base
  def static_cost(0x5A), do: @gas_base
  def static_cost(0x5B), do: @gas_jumpdest
  # TLOAD: EIP-1153, warm access cost
  def static_cost(0x5C), do: @gas_warm_access
  # TSTORE: EIP-1153, warm access cost
  def static_cost(0x5D), do: @gas_warm_access
  def static_cost(0x5E), do: @gas_very_low
  def static_cost(0x5F), do: @gas_base

  # 0x60–0x9F: PUSH, DUP, SWAP families
  def static_cost(op) when op >= 0x60 and op <= 0x7F, do: @gas_very_low
  def static_cost(op) when op >= 0x80 and op <= 0x8F, do: @gas_very_low
  def static_cost(op) when op >= 0x90 and op <= 0x9F, do: @gas_very_low

  # 0xA0–0xA4: LOG0–LOG4 (static base; dynamic cost per topic + data in Gas.Dynamic)
  def static_cost(op) when op in 0xA0..0xA4, do: @gas_log

  # 0xF0–0xFF: System
  def static_cost(0xF0), do: @gas_create
  # CALL: EIP-2929 warm access as base; value transfer + new account costs added dynamically
  def static_cost(0xF1), do: @gas_warm_access
  # CALLCODE: same base cost as CALL
  def static_cost(0xF2), do: @gas_warm_access
  def static_cost(0xF3), do: @gas_zero
  # DELEGATECALL: same base cost as CALL
  def static_cost(0xF4), do: @gas_warm_access
  def static_cost(0xF5), do: @gas_create
  # STATICCALL: same base cost as CALL
  def static_cost(0xFA), do: @gas_warm_access
  def static_cost(0xFD), do: @gas_zero
  def static_cost(0xFE), do: @gas_zero
  def static_cost(0xFF), do: @gas_selfdestruct

  # Unknown opcodes: zero static cost (will halt as invalid)
  def static_cost(_), do: @gas_zero
end
