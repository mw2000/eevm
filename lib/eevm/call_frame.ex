defmodule EEVM.CallFrame do
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
