defmodule EEVM.Opcodes do
  @moduledoc """
  EVM opcode definitions — maps byte values to their names and metadata.

  ## EVM Concepts

  Each EVM instruction is a single byte (0x00–0xFF). This module defines the
  mapping from byte values to human-readable names and metadata like how many
  stack items each instruction consumes and produces.

  ## Elixir Learning Notes

  - Module attributes (`@opcodes`) can hold complex data structures.
  - `Map` is the go-to key-value data structure in Elixir.
  - `for` comprehensions with `into: %{}` build maps from enumerable data.
  - Guards (`when`) add constraints to function clauses.
  """

  # --- Opcode byte values ---
  # Defining these as module attributes makes them available at compile time
  # and documents the hex values clearly.

  # Stop and Arithmetic (0x0_)
  @stop 0x00
  @add 0x01
  @mul 0x02
  @sub 0x03
  @div_ 0x04
  @sdiv 0x05
  @mod 0x06
  @smod 0x07
  @addmod 0x08
  @mulmod 0x09
  @exp 0x0A
  @signextend 0x0B

  # Comparison & Bitwise Logic (0x1_)
  @lt 0x10
  @gt 0x11
  @slt 0x12
  @sgt 0x13
  @eq 0x14
  @iszero 0x15
  @and_ 0x16
  @or_ 0x17
  @xor_ 0x18
  @not_ 0x19
  @byte_ 0x1A
  @shl 0x1B
  @shr 0x1C
  @sar 0x1D

  # Memory operations (0x5_)
  @pop 0x50
  @mload 0x51
  @mstore 0x52
  @mstore8 0x53
  @sload 0x54
  @sstore 0x55
  @msize 0x59
  @jump 0x56
  @jumpi 0x57
  @pc 0x58
  @jumpdest 0x5B

  # PUSH instructions (0x60–0x7F): PUSH1 through PUSH32
  @push1 0x60
  @push32 0x7F

  # DUP instructions (0x80–0x8F): DUP1 through DUP16
  @dup1 0x80
  @dup16 0x8F

  # SWAP instructions (0x90–0x9F): SWAP1 through SWAP16
  @swap1 0x90
  @swap16 0x9F

  # System operations
  @return_ 0xF3
  @revert 0xFD
  @invalid 0xFE

  @doc """
  Returns metadata for a given opcode byte.

  The returned map contains:
  - `:name` — human-readable name (e.g., "ADD")
  - `:inputs` — number of stack items consumed
  - `:outputs` — number of stack items produced
  """
  @spec info(non_neg_integer()) :: {:ok, map()} | {:error, :unknown_opcode}

  def info(@stop), do: {:ok, %{name: "STOP", inputs: 0, outputs: 0}}
  def info(@add), do: {:ok, %{name: "ADD", inputs: 2, outputs: 1}}
  def info(@mul), do: {:ok, %{name: "MUL", inputs: 2, outputs: 1}}
  def info(@sub), do: {:ok, %{name: "SUB", inputs: 2, outputs: 1}}
  def info(@div_), do: {:ok, %{name: "DIV", inputs: 2, outputs: 1}}
  def info(@sdiv), do: {:ok, %{name: "SDIV", inputs: 2, outputs: 1}}
  def info(@mod), do: {:ok, %{name: "MOD", inputs: 2, outputs: 1}}
  def info(@smod), do: {:ok, %{name: "SMOD", inputs: 2, outputs: 1}}
  def info(@addmod), do: {:ok, %{name: "ADDMOD", inputs: 3, outputs: 1}}
  def info(@mulmod), do: {:ok, %{name: "MULMOD", inputs: 3, outputs: 1}}
  def info(@exp), do: {:ok, %{name: "EXP", inputs: 2, outputs: 1}}
  def info(@signextend), do: {:ok, %{name: "SIGNEXTEND", inputs: 2, outputs: 1}}

  def info(@lt), do: {:ok, %{name: "LT", inputs: 2, outputs: 1}}
  def info(@gt), do: {:ok, %{name: "GT", inputs: 2, outputs: 1}}
  def info(@slt), do: {:ok, %{name: "SLT", inputs: 2, outputs: 1}}
  def info(@sgt), do: {:ok, %{name: "SGT", inputs: 2, outputs: 1}}
  def info(@eq), do: {:ok, %{name: "EQ", inputs: 2, outputs: 1}}
  def info(@iszero), do: {:ok, %{name: "ISZERO", inputs: 1, outputs: 1}}
  def info(@and_), do: {:ok, %{name: "AND", inputs: 2, outputs: 1}}
  def info(@or_), do: {:ok, %{name: "OR", inputs: 2, outputs: 1}}
  def info(@xor_), do: {:ok, %{name: "XOR", inputs: 2, outputs: 1}}
  def info(@not_), do: {:ok, %{name: "NOT", inputs: 1, outputs: 1}}
  def info(@byte_), do: {:ok, %{name: "BYTE", inputs: 2, outputs: 1}}
  def info(@shl), do: {:ok, %{name: "SHL", inputs: 2, outputs: 1}}
  def info(@shr), do: {:ok, %{name: "SHR", inputs: 2, outputs: 1}}
  def info(@sar), do: {:ok, %{name: "SAR", inputs: 2, outputs: 1}}

  def info(@pop), do: {:ok, %{name: "POP", inputs: 1, outputs: 0}}
  def info(@mload), do: {:ok, %{name: "MLOAD", inputs: 1, outputs: 1}}
  def info(@mstore), do: {:ok, %{name: "MSTORE", inputs: 2, outputs: 0}}
  def info(@mstore8), do: {:ok, %{name: "MSTORE8", inputs: 2, outputs: 0}}
  def info(@sload), do: {:ok, %{name: "SLOAD", inputs: 1, outputs: 1}}
  def info(@sstore), do: {:ok, %{name: "SSTORE", inputs: 2, outputs: 0}}
  def info(@msize), do: {:ok, %{name: "MSIZE", inputs: 0, outputs: 1}}
  def info(@jump), do: {:ok, %{name: "JUMP", inputs: 1, outputs: 0}}
  def info(@jumpi), do: {:ok, %{name: "JUMPI", inputs: 2, outputs: 0}}
  def info(@pc), do: {:ok, %{name: "PC", inputs: 0, outputs: 1}}
  def info(@jumpdest), do: {:ok, %{name: "JUMPDEST", inputs: 0, outputs: 0}}

  def info(@return_), do: {:ok, %{name: "RETURN", inputs: 2, outputs: 0}}
  def info(@revert), do: {:ok, %{name: "REVERT", inputs: 2, outputs: 0}}
  def info(@invalid), do: {:ok, %{name: "INVALID", inputs: 0, outputs: 0}}

  # PUSH1–PUSH32: push N bytes onto the stack
  def info(op) when op >= @push1 and op <= @push32 do
    n = op - @push1 + 1
    {:ok, %{name: "PUSH#{n}", inputs: 0, outputs: 1, push_bytes: n}}
  end

  # DUP1–DUP16: duplicate the Nth stack element
  def info(op) when op >= @dup1 and op <= @dup16 do
    n = op - @dup1 + 1
    {:ok, %{name: "DUP#{n}", inputs: n, outputs: n + 1, dup_depth: n - 1}}
  end

  # SWAP1–SWAP16: swap top with the (N+1)th element
  def info(op) when op >= @swap1 and op <= @swap16 do
    n = op - @swap1 + 1
    {:ok, %{name: "SWAP#{n}", inputs: n + 1, outputs: n + 1, swap_depth: n}}
  end

  def info(_), do: {:error, :unknown_opcode}

  @doc "Checks if an opcode byte is a PUSH instruction."
  @spec is_push?(non_neg_integer()) :: boolean()
  def is_push?(op), do: op >= @push1 and op <= @push32

  @doc "For a PUSH opcode, returns how many bytes to read."
  @spec push_bytes(non_neg_integer()) :: non_neg_integer()
  def push_bytes(op) when op >= @push1 and op <= @push32, do: op - @push1 + 1

  @doc "Checks if an opcode byte is a DUP instruction."
  @spec is_dup?(non_neg_integer()) :: boolean()
  def is_dup?(op), do: op >= @dup1 and op <= @dup16

  @doc "Checks if an opcode byte is a SWAP instruction."
  @spec is_swap?(non_neg_integer()) :: boolean()
  def is_swap?(op), do: op >= @swap1 and op <= @swap16
end
