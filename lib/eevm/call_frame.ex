defmodule EEVM.CallFrame do
  @moduledoc """
  Execution frame snapshot used for nested EVM calls.

  ## EVM Concepts

  Each CALL-like opcode creates a new execution context while suspending the
  parent context. This struct captures the parent frame so execution can return
  correctly after the child frame halts.

  A frame stores:

  - code and program counter
  - stack and memory
  - available gas for that frame
  - contract context (`msg.sender`, `msg.value`, `address`)
  - return write-back metadata (`return_offset`, `return_size`)
  - static-call mode and depth

  ## Elixir Learning Notes

  - This struct is a plain value object; frame transitions are handled in
    `EEVM.MachineState` and `EEVM.Executor`.
  - `from_state/2` acts as a focused constructor that copies only the fields
    needed to suspend and restore execution.
  """

  alias EEVM.{Memory, Stack}
  alias EEVM.Context.Contract

  @type t :: %__MODULE__{
          code: binary(),
          pc: non_neg_integer(),
          stack: Stack.t(),
          memory: Memory.t(),
          gas: non_neg_integer(),
          contract: Contract.t(),
          return_offset: non_neg_integer(),
          return_size: non_neg_integer(),
          is_static: boolean(),
          depth: non_neg_integer()
        }

  defstruct code: <<>>,
            pc: 0,
            stack: nil,
            memory: nil,
            gas: 0,
            contract: nil,
            return_offset: 0,
            return_size: 0,
            is_static: false,
            depth: 0

  @spec from_state(map(), keyword()) :: t()
  def from_state(state, opts \\ []) do
    %__MODULE__{
      code: state.code,
      pc: state.pc,
      stack: state.stack,
      memory: state.memory,
      gas: state.gas,
      contract: state.contract,
      return_offset: Keyword.get(opts, :return_offset, 0),
      return_size: Keyword.get(opts, :return_size, 0),
      is_static: Keyword.get(opts, :is_static, false),
      depth: Keyword.get(opts, :depth, 0)
    }
  end
end
