defmodule EEVM.Gas.Static do
  @moduledoc false

  @gas_zero 0
  @gas_base 2
  @gas_very_low 3
  @gas_low 5
  @gas_mid 8
  @gas_high 10
  @gas_jumpdest 1

  @gas_keccak256 30
  @gas_sload 200
  @gas_sstore 20_000
  @gas_blockhash 20
  @gas_balance 2600
  @gas_selfbalance 5
  @gas_log 375
  @gas_warm_access 100
  @gas_create 32_000

  @spec static_cost(non_neg_integer()) :: non_neg_integer()
  def static_cost(0x00), do: @gas_zero

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

  def static_cost(0x20), do: @gas_keccak256

  def static_cost(0x30), do: @gas_base
  def static_cost(0x31), do: @gas_balance
  def static_cost(0x32), do: @gas_base
  def static_cost(0x33), do: @gas_base
  def static_cost(0x34), do: @gas_base
  def static_cost(0x35), do: @gas_very_low
  def static_cost(0x36), do: @gas_base
  def static_cost(0x37), do: @gas_very_low
  def static_cost(0x38), do: @gas_base
  def static_cost(0x39), do: @gas_very_low
  def static_cost(0x3A), do: @gas_base
  def static_cost(0x3B), do: @gas_warm_access
  def static_cost(0x3C), do: @gas_warm_access
  def static_cost(0x3D), do: @gas_base
  def static_cost(0x3E), do: @gas_very_low
  def static_cost(0x3F), do: @gas_warm_access
  def static_cost(0x40), do: @gas_blockhash
  def static_cost(0x41), do: @gas_base
  def static_cost(0x42), do: @gas_base
  def static_cost(0x43), do: @gas_base
  def static_cost(0x44), do: @gas_base
  def static_cost(0x45), do: @gas_base
  def static_cost(0x46), do: @gas_base
  def static_cost(0x47), do: @gas_selfbalance
  def static_cost(0x48), do: @gas_base

  def static_cost(0x50), do: @gas_base
  def static_cost(0x51), do: @gas_very_low
  def static_cost(0x52), do: @gas_very_low
  def static_cost(0x53), do: @gas_very_low
  def static_cost(0x54), do: @gas_sload
  def static_cost(0x55), do: @gas_sstore
  def static_cost(0x56), do: @gas_mid
  def static_cost(0x57), do: @gas_high
  def static_cost(0x58), do: @gas_base
  def static_cost(0x59), do: @gas_base
  def static_cost(0x5A), do: @gas_base
  def static_cost(0x5B), do: @gas_jumpdest
  def static_cost(0x5E), do: @gas_very_low
  def static_cost(0x5F), do: @gas_base

  def static_cost(op) when op >= 0x60 and op <= 0x7F, do: @gas_very_low
  def static_cost(op) when op >= 0x80 and op <= 0x8F, do: @gas_very_low
  def static_cost(op) when op >= 0x90 and op <= 0x9F, do: @gas_very_low

  def static_cost(op) when op in 0xA0..0xA4, do: @gas_log

  def static_cost(0xF0), do: @gas_create
  def static_cost(0xF1), do: @gas_warm_access
  def static_cost(0xF2), do: @gas_warm_access
  def static_cost(0xF3), do: @gas_zero
  def static_cost(0xF4), do: @gas_warm_access
  def static_cost(0xF5), do: @gas_create
  def static_cost(0xFA), do: @gas_warm_access
  def static_cost(0xFD), do: @gas_zero
  def static_cost(0xFE), do: @gas_zero

  def static_cost(_), do: @gas_zero
end
