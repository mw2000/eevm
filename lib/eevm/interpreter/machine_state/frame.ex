defmodule EEVM.Interpreter.MachineState.Frame do
  @moduledoc """
  Per-call execution frame.

  A frame is everything that gets a fresh value when a CALL/CREATE-like
  opcode spawns a child, and that gets restored when the child halts:

  - `pc`, `stack`, `memory`, `gas`, `refund` — execution registers
  - `code` — the currently-executing bytecode
  - `return_data` — buffer holding the most recent child frame's output
  - `contract` — the per-call message context (`msg.sender`, `msg.value`,
    `address`, `calldata`, `balances`)
  - `depth` — the EVM call depth (max 1024)
  - `is_static` — STATICCALL flag; state-mutating opcodes revert under it
  - `return_offset` / `return_size` — where in the *parent's* memory the
    child should write its return data

  The active frame lives at `MachineState.frame`; suspended parent frames
  live in `MachineState.call_stack` as the same struct. `push_frame` and
  `pop_frame` move frames between the two.
  """

  alias EEVM.Context.Contract
  alias EEVM.Interpreter.{Memory, Stack}

  @type t :: %__MODULE__{
          pc: non_neg_integer(),
          stack: Stack.t(),
          memory: Memory.t(),
          gas: non_neg_integer(),
          refund: non_neg_integer(),
          code: binary(),
          return_data: binary(),
          contract: Contract.t(),
          depth: non_neg_integer(),
          is_static: boolean(),
          return_offset: non_neg_integer(),
          return_size: non_neg_integer()
        }

  defstruct pc: 0,
            stack: nil,
            memory: nil,
            gas: 0,
            refund: 0,
            code: <<>>,
            return_data: <<>>,
            contract: nil,
            depth: 0,
            is_static: false,
            return_offset: 0,
            return_size: 0
end
