defmodule EEVM.Interpreter.Instructions.Registry do
  @moduledoc """
  Opcode metadata registry — single source of truth for every opcode's name,
  stack I/O signature, implementing module, and static-context flag.

  Given an opcode byte (0x00–0xFF) `info/1` returns:

  - `:name` — the human-readable mnemonic (e.g. `"ADD"`)
  - `:inputs` / `:outputs` — stack arity, used by the disassembler and stack-depth checks
  - `:module` — the `EEVM.Interpreter.Instructions.*` module that implements
    the opcode; `EEVM.Interpreter` dispatches on this field
  - `:kind` — how the interpreter runs it:
    - `:stack` opcodes are pure functions of the stack, implemented as
      `module.stack_op(opcode, stack)` on a list; this is the default for the
      Arithmetic, Comparison, Bitwise, and StackOps modules.
    - `:control` opcodes (PUSH0–PUSH32, JUMP, JUMPI, JUMPDEST, PC, GAS) read or
      move the interpreter loop's own registers, so `EEVM.Interpreter`
      implements them.
    - `:state` opcodes read or write the machine state through
      `module.execute(opcode, state)`.
  - `:state_mutating` (when present) — opcode mutates persistent state and is an
    exceptional halt (`{:error, :static_state_modification}`) inside a STATICCALL frame
  - `:eip` (when present) — the `EEVM.HardforkConfig` flag of the EIP that
    introduced the opcode; before that EIP activates the byte is undefined.
    Opcodes without it exist since Frontier. `EEVM.Interpreter.InstructionTable`
    applies this per hardfork.

  PUSH1–PUSH32, DUP1–DUP16, and SWAP1–SWAP16 are generated dynamically from their
  opcode ranges rather than stored in the static map.
  """

  alias EEVM.Interpreter

  alias EEVM.Interpreter.Instructions.{
    Arithmetic,
    Bitwise,
    Comparison,
    Crypto,
    Environment.Data,
    Environment.External,
    Environment.Simple,
    Logging,
    StackMemoryStorage.MemoryOps,
    StackMemoryStorage.StackOps,
    StackMemoryStorage.StorageOps,
    System.Calls,
    System.Creation,
    System.Termination
  }

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
  @clz 0x1E

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
  @blobhash 0x49
  @blobbasefee 0x4A
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
  @tload 0x5C
  @tstore 0x5D
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
  @callcode 0xF2
  @return_ 0xF3
  @delegatecall 0xF4
  @create2 0xF5
  @staticcall 0xFA
  @selfdestruct 0xFF
  @revert 0xFD
  @invalid 0xFE

  @opcodes %{
    @stop => %{name: "STOP", inputs: 0, outputs: 0, module: Termination},
    @add => %{name: "ADD", inputs: 2, outputs: 1, module: Arithmetic},
    @mul => %{name: "MUL", inputs: 2, outputs: 1, module: Arithmetic},
    @sub => %{name: "SUB", inputs: 2, outputs: 1, module: Arithmetic},
    @div_ => %{name: "DIV", inputs: 2, outputs: 1, module: Arithmetic},
    @sdiv => %{name: "SDIV", inputs: 2, outputs: 1, module: Arithmetic},
    @mod => %{name: "MOD", inputs: 2, outputs: 1, module: Arithmetic},
    @smod => %{name: "SMOD", inputs: 2, outputs: 1, module: Arithmetic},
    @addmod => %{name: "ADDMOD", inputs: 3, outputs: 1, module: Arithmetic},
    @mulmod => %{name: "MULMOD", inputs: 3, outputs: 1, module: Arithmetic},
    # EXP's gas depends on its exponent (EIP-160), so it needs the machine state.
    @exp => %{name: "EXP", inputs: 2, outputs: 1, module: Arithmetic, kind: :state},
    @signextend => %{name: "SIGNEXTEND", inputs: 2, outputs: 1, module: Arithmetic},
    @keccak256 => %{name: "KECCAK256", inputs: 2, outputs: 1, module: Crypto},
    @lt => %{name: "LT", inputs: 2, outputs: 1, module: Comparison},
    @gt => %{name: "GT", inputs: 2, outputs: 1, module: Comparison},
    @slt => %{name: "SLT", inputs: 2, outputs: 1, module: Comparison},
    @sgt => %{name: "SGT", inputs: 2, outputs: 1, module: Comparison},
    @eq => %{name: "EQ", inputs: 2, outputs: 1, module: Comparison},
    @iszero => %{name: "ISZERO", inputs: 1, outputs: 1, module: Comparison},
    @and_ => %{name: "AND", inputs: 2, outputs: 1, module: Bitwise},
    @or_ => %{name: "OR", inputs: 2, outputs: 1, module: Bitwise},
    @xor_ => %{name: "XOR", inputs: 2, outputs: 1, module: Bitwise},
    @not_ => %{name: "NOT", inputs: 1, outputs: 1, module: Bitwise},
    @byte_ => %{name: "BYTE", inputs: 2, outputs: 1, module: Bitwise},
    @shl => %{name: "SHL", inputs: 2, outputs: 1, module: Bitwise, eip: :eip_145},
    @shr => %{name: "SHR", inputs: 2, outputs: 1, module: Bitwise, eip: :eip_145},
    @sar => %{name: "SAR", inputs: 2, outputs: 1, module: Bitwise, eip: :eip_145},
    @clz => %{name: "CLZ", inputs: 1, outputs: 1, module: Bitwise, eip: :eip_7939},
    @address => %{name: "ADDRESS", inputs: 0, outputs: 1, module: Simple},
    @balance => %{name: "BALANCE", inputs: 1, outputs: 1, module: External},
    @origin => %{name: "ORIGIN", inputs: 0, outputs: 1, module: Simple},
    @caller => %{name: "CALLER", inputs: 0, outputs: 1, module: Simple},
    @callvalue => %{name: "CALLVALUE", inputs: 0, outputs: 1, module: Simple},
    @calldataload => %{name: "CALLDATALOAD", inputs: 1, outputs: 1, module: Data},
    @calldatasize => %{name: "CALLDATASIZE", inputs: 0, outputs: 1, module: Simple},
    @calldatacopy => %{name: "CALLDATACOPY", inputs: 3, outputs: 0, module: Data},
    @codecopy => %{name: "CODECOPY", inputs: 3, outputs: 0, module: Data},
    @extcodecopy => %{name: "EXTCODECOPY", inputs: 4, outputs: 0, module: External},
    @returndatacopy => %{
      name: "RETURNDATACOPY",
      inputs: 3,
      outputs: 0,
      module: Data,
      eip: :eip_211
    },
    @codesize => %{name: "CODESIZE", inputs: 0, outputs: 1, module: Simple},
    @extcodesize => %{name: "EXTCODESIZE", inputs: 1, outputs: 1, module: External},
    @gasprice => %{name: "GASPRICE", inputs: 0, outputs: 1, module: Simple},
    @returndatasize => %{
      name: "RETURNDATASIZE",
      inputs: 0,
      outputs: 1,
      module: Simple,
      eip: :eip_211
    },
    @extcodehash => %{
      name: "EXTCODEHASH",
      inputs: 1,
      outputs: 1,
      module: External,
      eip: :eip_1052
    },
    @blockhash => %{name: "BLOCKHASH", inputs: 1, outputs: 1, module: Simple},
    @coinbase => %{name: "COINBASE", inputs: 0, outputs: 1, module: Simple},
    @timestamp => %{name: "TIMESTAMP", inputs: 0, outputs: 1, module: Simple},
    @number => %{name: "NUMBER", inputs: 0, outputs: 1, module: Simple},
    @prevrandao => %{name: "PREVRANDAO", inputs: 0, outputs: 1, module: Simple},
    @gaslimit => %{name: "GASLIMIT", inputs: 0, outputs: 1, module: Simple},
    @chainid => %{name: "CHAINID", inputs: 0, outputs: 1, module: Simple, eip: :eip_1344},
    @selfbalance => %{
      name: "SELFBALANCE",
      inputs: 0,
      outputs: 1,
      module: External,
      eip: :eip_1884
    },
    @basefee => %{name: "BASEFEE", inputs: 0, outputs: 1, module: Simple, eip: :eip_3198},
    @blobhash => %{name: "BLOBHASH", inputs: 1, outputs: 1, module: Simple, eip: :eip_4844},
    @blobbasefee => %{name: "BLOBBASEFEE", inputs: 0, outputs: 1, module: Simple, eip: :eip_7516},
    @gas_ => %{name: "GAS", inputs: 0, outputs: 1, module: Interpreter, kind: :control},
    @push0 => %{
      name: "PUSH0",
      inputs: 0,
      outputs: 1,
      module: Interpreter,
      kind: :control,
      eip: :eip_3855
    },
    @pop => %{name: "POP", inputs: 1, outputs: 0, module: StackOps},
    @mload => %{name: "MLOAD", inputs: 1, outputs: 1, module: MemoryOps},
    @mstore => %{name: "MSTORE", inputs: 2, outputs: 0, module: MemoryOps},
    @mstore8 => %{name: "MSTORE8", inputs: 2, outputs: 0, module: MemoryOps},
    @sload => %{name: "SLOAD", inputs: 1, outputs: 1, module: StorageOps},
    @sstore => %{name: "SSTORE", inputs: 2, outputs: 0, module: StorageOps, state_mutating: true},
    @tload => %{name: "TLOAD", inputs: 1, outputs: 1, module: StorageOps, eip: :eip_1153},
    @tstore => %{
      name: "TSTORE",
      inputs: 2,
      outputs: 0,
      module: StorageOps,
      state_mutating: true,
      eip: :eip_1153
    },
    @msize => %{name: "MSIZE", inputs: 0, outputs: 1, module: MemoryOps},
    @mcopy => %{name: "MCOPY", inputs: 3, outputs: 0, module: MemoryOps, eip: :eip_5656},
    @jump => %{name: "JUMP", inputs: 1, outputs: 0, module: Interpreter, kind: :control},
    @jumpi => %{name: "JUMPI", inputs: 2, outputs: 0, module: Interpreter, kind: :control},
    @pc => %{name: "PC", inputs: 0, outputs: 1, module: Interpreter, kind: :control},
    @jumpdest => %{name: "JUMPDEST", inputs: 0, outputs: 0, module: Interpreter, kind: :control},
    @log0 => %{name: "LOG0", inputs: 2, outputs: 0, module: Logging, state_mutating: true},
    @log1 => %{name: "LOG1", inputs: 3, outputs: 0, module: Logging, state_mutating: true},
    @log2 => %{name: "LOG2", inputs: 4, outputs: 0, module: Logging, state_mutating: true},
    @log3 => %{name: "LOG3", inputs: 5, outputs: 0, module: Logging, state_mutating: true},
    @log4 => %{name: "LOG4", inputs: 6, outputs: 0, module: Logging, state_mutating: true},
    @create => %{name: "CREATE", inputs: 3, outputs: 1, module: Creation, state_mutating: true},
    @call => %{name: "CALL", inputs: 7, outputs: 1, module: Calls},
    @callcode => %{name: "CALLCODE", inputs: 7, outputs: 1, module: Calls},
    @delegatecall => %{name: "DELEGATECALL", inputs: 6, outputs: 1, module: Calls, eip: :eip_7},
    @create2 => %{
      name: "CREATE2",
      inputs: 4,
      outputs: 1,
      module: Creation,
      state_mutating: true,
      eip: :eip_1014
    },
    @staticcall => %{name: "STATICCALL", inputs: 6, outputs: 1, module: Calls, eip: :eip_214},
    @return_ => %{name: "RETURN", inputs: 2, outputs: 0, module: Termination},
    @revert => %{name: "REVERT", inputs: 2, outputs: 0, module: Termination, eip: :eip_140},
    @invalid => %{name: "INVALID", inputs: 0, outputs: 0, module: Termination},
    @selfdestruct => %{
      name: "SELFDESTRUCT",
      inputs: 1,
      outputs: 0,
      module: Termination,
      state_mutating: true
    }
  }

  # Entries of the pure-stack modules default to `kind: :stack`; EXP overrides it.
  @stack_modules [Arithmetic, Bitwise, Comparison, StackOps]
  @opcodes (for {op, info} <- @opcodes, into: %{} do
              default_kind = if info.module in @stack_modules, do: :stack, else: :state
              {op, Map.put_new(info, :kind, default_kind)}
            end)

  @spec info(non_neg_integer()) :: {:ok, map()} | {:error, :unknown_opcode}
  def info(op) when op >= @push1 and op <= @push32 do
    n = op - @push1 + 1

    {:ok,
     %{
       name: "PUSH#{n}",
       inputs: 0,
       outputs: 1,
       push_bytes: n,
       module: Interpreter,
       kind: :control
     }}
  end

  def info(op) when op >= @dup1 and op <= @dup16 do
    n = op - @dup1 + 1

    {:ok,
     %{
       name: "DUP#{n}",
       inputs: n,
       outputs: n + 1,
       dup_depth: n - 1,
       module: StackOps,
       kind: :stack
     }}
  end

  def info(op) when op >= @swap1 and op <= @swap16 do
    n = op - @swap1 + 1

    {:ok,
     %{
       name: "SWAP#{n}",
       inputs: n + 1,
       outputs: n + 1,
       swap_depth: n,
       module: StackOps,
       kind: :stack
     }}
  end

  def info(op) do
    case Map.fetch(@opcodes, op) do
      {:ok, info} -> {:ok, info}
      :error -> {:error, :unknown_opcode}
    end
  end

  @spec push?(non_neg_integer()) :: boolean()
  def push?(op), do: op >= @push1 and op <= @push32

  @spec push_bytes(non_neg_integer()) :: non_neg_integer()
  def push_bytes(op) when op >= @push1 and op <= @push32, do: op - @push1 + 1

  @spec dup?(non_neg_integer()) :: boolean()
  def dup?(op), do: op >= @dup1 and op <= @dup16

  @spec swap?(non_neg_integer()) :: boolean()
  def swap?(op), do: op >= @swap1 and op <= @swap16
end
