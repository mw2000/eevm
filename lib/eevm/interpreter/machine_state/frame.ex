defmodule EEVM.Interpreter.MachineState.Frame do
  @moduledoc """
  Per-call execution frame.

  A frame is everything that gets a fresh value when a CALL/CREATE-like
  opcode spawns a child, and that gets restored when the child halts:

  - `pc`, `stack`, `memory`, `gas`, `refund` — execution registers
  - `code` — the currently-executing bytecode
  - `jumpdests` — `code`'s JUMPDEST map, filled in by the frame's first
    JUMP/JUMPI (see `EEVM.Interpreter.Instructions.Helpers.check_jumpdest/2`)
  - `return_data` — buffer holding the most recent child frame's output
  - `contract` — the per-call message context (`msg.sender`, `msg.value`,
    `address`, `calldata`, `balances`)
  - `depth` — the EVM call depth (max 1024)
  - `is_static` — STATICCALL flag; state-mutating opcodes revert under it

  The active frame lives at `MachineState.frame`. CALL and CREATE run a
  child frame in a nested `EEVM.Interpreter.run_loop/1` and copy its result
  back into the parent frame.
  """

  alias EEVM.Context.Contract
  alias EEVM.Interpreter.{Memory, Stack}

  @type t :: %__MODULE__{
          pc: non_neg_integer(),
          stack: Stack.t(),
          memory: Memory.t(),
          gas: non_neg_integer(),
          refund: integer(),
          code: binary(),
          jumpdests: binary() | nil,
          return_data: binary(),
          contract: Contract.t(),
          depth: non_neg_integer(),
          is_static: boolean()
        }

  defstruct pc: 0,
            stack: nil,
            memory: nil,
            gas: 0,
            refund: 0,
            code: <<>>,
            jumpdests: nil,
            return_data: <<>>,
            contract: nil,
            depth: 0,
            is_static: false
end
