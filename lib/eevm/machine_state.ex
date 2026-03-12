defmodule EEVM.MachineState do
  @moduledoc """
  The EVM machine state — holds all mutable state during execution.

  ## EVM Concepts

  The machine state consists of:
  - **pc** (program counter): points to the current instruction
  - **stack**: the operand stack (max 1024 elements)
  - **memory**: byte-addressable linear memory
  - **world_state**: account/code state used for external account lookups
  - **gas**: remaining gas for execution
  - **status**: whether the machine is running, stopped, or reverted

  ## Elixir Learning Notes

  - Structs in Elixir are just maps with a `__struct__` key. They give you
    compile-time guarantees about which fields exist.
  - `@enforce_keys` makes certain fields required when creating a struct.
  - We use atoms like `:running`, `:stopped`, `:reverted` for status —
    atoms are constants whose name IS their value (like symbols in Ruby).
  - The `alias` keyword lets us reference modules by their short name.
  """

  alias EEVM.{CallFrame, Memory, Stack, Storage, WorldState}
  alias EEVM.Context.{Block, Contract, Transaction}

  @type status :: :running | :stopped | :reverted | :invalid | :out_of_gas

  @type t :: %__MODULE__{
          pc: non_neg_integer(),
          stack: Stack.t(),
          memory: Memory.t(),
          storage: Storage.t(),
          tx: Transaction.t(),
          block: Block.t(),
          contract: Contract.t(),
          world_state: WorldState.t(),
          call_stack: [CallFrame.t()],
          frame_return_offset: non_neg_integer(),
          frame_return_size: non_neg_integer(),
          is_static: boolean(),
          depth: non_neg_integer(),
          gas: non_neg_integer(),
          status: status(),
          return_data: binary(),
          logs: [%{address: non_neg_integer(), data: binary(), topics: [non_neg_integer()]}],
          code: binary()
        }

  @enforce_keys [:code]
  defstruct pc: 0,
            stack: nil,
            memory: nil,
            storage: nil,
            tx: nil,
            block: nil,
            contract: nil,
            world_state: nil,
            call_stack: [],
            frame_return_offset: 0,
            frame_return_size: 0,
            is_static: false,
            depth: 0,
            gas: 1_000_000,
            status: :running,
            return_data: <<>>,
            logs: [],
            code: <<>>

  @doc """
  Creates a new machine state for executing the given bytecode.

  ## Parameters
    - `code` — the raw EVM bytecode as an Elixir binary
    - `opts` — optional keyword list:
      - `:gas` — initial gas (default: 1,000,000)
      - `:storage` — initial storage (default: empty)
      - `:tx` — transaction context (default: empty)
      - `:block` — block context (default: empty)
      - `:contract` — contract/message context (default: empty)
      - `:world_state` — external account state (default: empty)

  ## Example

      iex> state = EEVM.MachineState.new(<<0x60, 0x01, 0x60, 0x02, 0x01>>)
      iex> state.pc
      0
  """
  @spec new(binary(), keyword()) :: t()
  def new(code, opts \\ []) do
    %__MODULE__{
      code: code,
      stack: Stack.new(),
      memory: Memory.new(),
      storage: Keyword.get(opts, :storage, Storage.new()),
      tx: Keyword.get(opts, :tx, Transaction.new()),
      block: Keyword.get(opts, :block, Block.new()),
      contract: Keyword.get(opts, :contract, Contract.new()),
      world_state: Keyword.get(opts, :world_state, WorldState.new()),
      call_stack: Keyword.get(opts, :call_stack, []),
      frame_return_offset: Keyword.get(opts, :frame_return_offset, 0),
      frame_return_size: Keyword.get(opts, :frame_return_size, 0),
      is_static: Keyword.get(opts, :is_static, false),
      depth: Keyword.get(opts, :depth, 0),
      return_data: Keyword.get(opts, :return_data, <<>>),
      gas: Keyword.get(opts, :gas, 1_000_000)
    }
  end

  @doc "Returns the opcode byte at the current program counter, or nil if past end."
  @spec current_opcode(t()) :: non_neg_integer() | nil
  def current_opcode(%__MODULE__{pc: pc, code: code}) when pc < byte_size(code) do
    :binary.at(code, pc)
  end

  def current_opcode(_state), do: nil

  @doc """
  Reads `n` bytes from the code starting at `offset`.

  Used by PUSH instructions to read their immediate data.
  """
  @spec read_code(t(), non_neg_integer(), non_neg_integer()) :: binary()
  def read_code(%__MODULE__{code: code}, offset, n) do
    code_size = byte_size(code)

    if offset >= code_size do
      # Past end of code — return zeros (EVM spec: treat as 0x00)
      <<0::size(n * 8)>>
    else
      available = min(n, code_size - offset)
      chunk = binary_part(code, offset, available)
      # Pad with zeros if we read past the end
      padding_size = (n - available) * 8
      <<chunk::binary, 0::size(padding_size)>>
    end
  end

  @doc "Advances the program counter by `n` positions."
  @spec advance_pc(t(), non_neg_integer()) :: t()
  def advance_pc(state, n \\ 1) do
    %{state | pc: state.pc + n}
  end

  @spec current_depth(t()) :: non_neg_integer()
  def current_depth(%__MODULE__{depth: depth}), do: depth

  @spec push_frame(t(), CallFrame.t()) :: {:ok, t()} | {:error, :max_call_depth, t()}
  def push_frame(%__MODULE__{depth: depth} = state, _new_frame) when depth >= 1024 do
    {:error, :max_call_depth, state}
  end

  def push_frame(%__MODULE__{} = state, %CallFrame{} = new_frame) do
    parent_frame =
      CallFrame.from_state(state,
        return_offset: state.frame_return_offset,
        return_size: state.frame_return_size,
        is_static: state.is_static,
        depth: state.depth
      )

    {:ok,
     %{
       state
       | call_stack: [parent_frame | state.call_stack],
         code: new_frame.code,
         pc: new_frame.pc,
         stack: new_frame.stack,
         memory: new_frame.memory,
         gas: new_frame.gas,
         contract: new_frame.contract,
         frame_return_offset: new_frame.return_offset,
         frame_return_size: new_frame.return_size,
         is_static: new_frame.is_static,
         depth: new_frame.depth,
         status: :running,
         return_data: <<>>
     }}
  end

  @spec pop_frame(t()) :: {:ok, t()} | {:error, :empty_call_stack, t()}
  def pop_frame(%__MODULE__{call_stack: []} = state), do: {:error, :empty_call_stack, state}

  def pop_frame(%__MODULE__{call_stack: [parent | rest]} = state) do
    child_return_data = state.return_data

    {parent_memory, _} =
      write_return_data(
        parent.memory,
        state.frame_return_offset,
        state.frame_return_size,
        child_return_data
      )

    restored_state =
      %{
        state
        | call_stack: rest,
          code: parent.code,
          pc: parent.pc,
          stack: parent.stack,
          memory: parent_memory,
          gas: parent.gas + state.gas,
          contract: parent.contract,
          frame_return_offset: parent.return_offset,
          frame_return_size: parent.return_size,
          is_static: parent.is_static,
          depth: parent.depth,
          status: :running,
          return_data: child_return_data
      }

    {:ok, restored_state}
  end

  @doc """
  Deducts gas from the machine state.

  Returns `{:ok, updated_state}` if sufficient gas remains, or
  `{:error, :out_of_gas, state}` if the gas would go negative.

  ## Elixir Learning Note

  This uses a guard clause (`when cost <= gas`) to branch at the function
  head level — no `if/else` needed. The first clause matches when we have
  enough gas, the second is the fallback.
  """
  @spec consume_gas(t(), non_neg_integer()) :: {:ok, t()} | {:error, :out_of_gas, t()}
  def consume_gas(%__MODULE__{gas: gas} = state, cost) when cost <= gas do
    {:ok, %{state | gas: gas - cost}}
  end

  def consume_gas(state, _cost) do
    {:error, :out_of_gas, halt(state, :out_of_gas)}
  end

  @doc "Returns the gas remaining."
  @spec gas_remaining(t()) :: non_neg_integer()
  def gas_remaining(%__MODULE__{gas: gas}), do: gas

  @doc "Halts execution with the given status."
  @spec halt(t(), status()) :: t()
  def halt(state, status) do
    %{state | status: status}
  end

  defp write_return_data(memory, _offset, 0, return_data), do: {memory, return_data}

  defp write_return_data(memory, offset, size, return_data) do
    bytes =
      for i <- 0..(size - 1), into: <<>> do
        if i < byte_size(return_data), do: <<:binary.at(return_data, i)>>, else: <<0>>
      end

    new_memory =
      bytes
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.reduce(memory, fn {byte, i}, mem ->
        Memory.store_byte(mem, offset + i, byte)
      end)

    {new_memory, return_data}
  end
end
