defmodule EEVM.Opcodes.Registry do
  @moduledoc false

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

  @keccak256 0x20
  @push0 0x5F

  @address 0x30
  @balance 0x31
  @origin 0x32
  @caller 0x33
  @callvalue 0x34
  @calldataload 0x35
  @calldatasize 0x36
  @calldatacopy 0x37
  @codesize 0x38
  @codecopy 0x39
  @gasprice 0x3A
  @extcodesize 0x3B
  @extcodecopy 0x3C
  @returndatasize 0x3D
  @returndatacopy 0x3E
  @extcodehash 0x3F
  @blockhash 0x40
  @coinbase 0x41
  @timestamp 0x42
  @number 0x43
  @prevrandao 0x44
  @gaslimit 0x45
  @chainid 0x46
  @selfbalance 0x47
  @basefee 0x48
  @gas_ 0x5A

  @pop 0x50
  @mload 0x51
  @mstore 0x52
  @mstore8 0x53
  @sload 0x54
  @sstore 0x55
  @jump 0x56
  @jumpi 0x57
  @pc 0x58
  @msize 0x59
  @mcopy 0x5E
  @jumpdest 0x5B

  @push1 0x60
  @push32 0x7F
  @dup1 0x80
  @dup16 0x8F
  @swap1 0x90
  @swap16 0x9F

  @log0 0xA0
  @log1 0xA1
  @log2 0xA2
  @log3 0xA3
  @log4 0xA4

  @create 0xF0
  @call 0xF1
  @return_ 0xF3
  @create2 0xF5
  @staticcall 0xFA
  @revert 0xFD
  @invalid 0xFE

  @opcodes %{
    @stop => %{name: "STOP", inputs: 0, outputs: 0},
    @add => %{name: "ADD", inputs: 2, outputs: 1},
    @mul => %{name: "MUL", inputs: 2, outputs: 1},
    @sub => %{name: "SUB", inputs: 2, outputs: 1},
    @div_ => %{name: "DIV", inputs: 2, outputs: 1},
    @sdiv => %{name: "SDIV", inputs: 2, outputs: 1},
    @mod => %{name: "MOD", inputs: 2, outputs: 1},
    @smod => %{name: "SMOD", inputs: 2, outputs: 1},
    @addmod => %{name: "ADDMOD", inputs: 3, outputs: 1},
    @mulmod => %{name: "MULMOD", inputs: 3, outputs: 1},
    @exp => %{name: "EXP", inputs: 2, outputs: 1},
    @signextend => %{name: "SIGNEXTEND", inputs: 2, outputs: 1},
    @keccak256 => %{name: "KECCAK256", inputs: 2, outputs: 1},
    @lt => %{name: "LT", inputs: 2, outputs: 1},
    @gt => %{name: "GT", inputs: 2, outputs: 1},
    @slt => %{name: "SLT", inputs: 2, outputs: 1},
    @sgt => %{name: "SGT", inputs: 2, outputs: 1},
    @eq => %{name: "EQ", inputs: 2, outputs: 1},
    @iszero => %{name: "ISZERO", inputs: 1, outputs: 1},
    @and_ => %{name: "AND", inputs: 2, outputs: 1},
    @or_ => %{name: "OR", inputs: 2, outputs: 1},
    @xor_ => %{name: "XOR", inputs: 2, outputs: 1},
    @not_ => %{name: "NOT", inputs: 1, outputs: 1},
    @byte_ => %{name: "BYTE", inputs: 2, outputs: 1},
    @shl => %{name: "SHL", inputs: 2, outputs: 1},
    @shr => %{name: "SHR", inputs: 2, outputs: 1},
    @sar => %{name: "SAR", inputs: 2, outputs: 1},
    @address => %{name: "ADDRESS", inputs: 0, outputs: 1},
    @balance => %{name: "BALANCE", inputs: 1, outputs: 1},
    @origin => %{name: "ORIGIN", inputs: 0, outputs: 1},
    @caller => %{name: "CALLER", inputs: 0, outputs: 1},
    @callvalue => %{name: "CALLVALUE", inputs: 0, outputs: 1},
    @calldataload => %{name: "CALLDATALOAD", inputs: 1, outputs: 1},
    @calldatasize => %{name: "CALLDATASIZE", inputs: 0, outputs: 1},
    @calldatacopy => %{name: "CALLDATACOPY", inputs: 3, outputs: 0},
    @codecopy => %{name: "CODECOPY", inputs: 3, outputs: 0},
    @extcodecopy => %{name: "EXTCODECOPY", inputs: 4, outputs: 0},
    @returndatacopy => %{name: "RETURNDATACOPY", inputs: 3, outputs: 0},
    @codesize => %{name: "CODESIZE", inputs: 0, outputs: 1},
    @extcodesize => %{name: "EXTCODESIZE", inputs: 1, outputs: 1},
    @gasprice => %{name: "GASPRICE", inputs: 0, outputs: 1},
    @returndatasize => %{name: "RETURNDATASIZE", inputs: 0, outputs: 1},
    @extcodehash => %{name: "EXTCODEHASH", inputs: 1, outputs: 1},
    @blockhash => %{name: "BLOCKHASH", inputs: 1, outputs: 1},
    @coinbase => %{name: "COINBASE", inputs: 0, outputs: 1},
    @timestamp => %{name: "TIMESTAMP", inputs: 0, outputs: 1},
    @number => %{name: "NUMBER", inputs: 0, outputs: 1},
    @prevrandao => %{name: "PREVRANDAO", inputs: 0, outputs: 1},
    @gaslimit => %{name: "GASLIMIT", inputs: 0, outputs: 1},
    @chainid => %{name: "CHAINID", inputs: 0, outputs: 1},
    @selfbalance => %{name: "SELFBALANCE", inputs: 0, outputs: 1},
    @basefee => %{name: "BASEFEE", inputs: 0, outputs: 1},
    @gas_ => %{name: "GAS", inputs: 0, outputs: 1},
    @push0 => %{name: "PUSH0", inputs: 0, outputs: 1},
    @pop => %{name: "POP", inputs: 1, outputs: 0},
    @mload => %{name: "MLOAD", inputs: 1, outputs: 1},
    @mstore => %{name: "MSTORE", inputs: 2, outputs: 0},
    @mstore8 => %{name: "MSTORE8", inputs: 2, outputs: 0},
    @sload => %{name: "SLOAD", inputs: 1, outputs: 1},
    @sstore => %{name: "SSTORE", inputs: 2, outputs: 0},
    @msize => %{name: "MSIZE", inputs: 0, outputs: 1},
    @mcopy => %{name: "MCOPY", inputs: 3, outputs: 0},
    @jump => %{name: "JUMP", inputs: 1, outputs: 0},
    @jumpi => %{name: "JUMPI", inputs: 2, outputs: 0},
    @pc => %{name: "PC", inputs: 0, outputs: 1},
    @jumpdest => %{name: "JUMPDEST", inputs: 0, outputs: 0},
    @log0 => %{name: "LOG0", inputs: 2, outputs: 0},
    @log1 => %{name: "LOG1", inputs: 3, outputs: 0},
    @log2 => %{name: "LOG2", inputs: 4, outputs: 0},
    @log3 => %{name: "LOG3", inputs: 5, outputs: 0},
    @log4 => %{name: "LOG4", inputs: 6, outputs: 0},
    @create => %{name: "CREATE", inputs: 3, outputs: 1},
    @call => %{name: "CALL", inputs: 7, outputs: 1},
    @create2 => %{name: "CREATE2", inputs: 4, outputs: 1},
    @staticcall => %{name: "STATICCALL", inputs: 6, outputs: 1},
    @return_ => %{name: "RETURN", inputs: 2, outputs: 0},
    @revert => %{name: "REVERT", inputs: 2, outputs: 0},
    @invalid => %{name: "INVALID", inputs: 0, outputs: 0}
  }

  @spec info(non_neg_integer()) :: {:ok, map()} | {:error, :unknown_opcode}
  def info(op) when op >= @push1 and op <= @push32 do
    n = op - @push1 + 1
    {:ok, %{name: "PUSH#{n}", inputs: 0, outputs: 1, push_bytes: n}}
  end

  def info(op) when op >= @dup1 and op <= @dup16 do
    n = op - @dup1 + 1
    {:ok, %{name: "DUP#{n}", inputs: n, outputs: n + 1, dup_depth: n - 1}}
  end

  def info(op) when op >= @swap1 and op <= @swap16 do
    n = op - @swap1 + 1
    {:ok, %{name: "SWAP#{n}", inputs: n + 1, outputs: n + 1, swap_depth: n}}
  end

  def info(op) do
    case Map.fetch(@opcodes, op) do
      {:ok, info} -> {:ok, info}
      :error -> {:error, :unknown_opcode}
    end
  end

  @spec is_push?(non_neg_integer()) :: boolean()
  def is_push?(op), do: op >= @push1 and op <= @push32

  @spec push_bytes(non_neg_integer()) :: non_neg_integer()
  def push_bytes(op) when op >= @push1 and op <= @push32, do: op - @push1 + 1

  @spec is_dup?(non_neg_integer()) :: boolean()
  def is_dup?(op), do: op >= @dup1 and op <= @dup16

  @spec is_swap?(non_neg_integer()) :: boolean()
  def is_swap?(op), do: op >= @swap1 and op <= @swap16
end
