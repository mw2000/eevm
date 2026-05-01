defmodule EEVM.Interpreter.MachineState do
  @moduledoc """
  The EVM machine state — holds all mutable state during execution.

  ## EVM Concepts

  The machine state consists of:
  - **pc** (program counter): points to the current instruction
  - **stack**: the operand stack (max 1024 elements)
  - **memory**: byte-addressable linear memory
  - **db**: unified external state backend (accounts + contract storage)
  - **call_stack**: suspended parent frames during nested execution
  - **frame return metadata**: parent memory write-back offset and size
  - **is_static/depth**: execution mode and current call depth
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

  alias EEVM.Config
  alias EEVM.Context.{Block, Contract, Transaction}
  alias EEVM.Database
  alias EEVM.Database.InMemory, as: InMemoryDB
  alias EEVM.Interpreter.{CallFrame, Memory, Stack}
  alias EEVM.Interpreter.MachineState.{Env, Substate}
  alias EEVM.Precompiles
  alias EEVM.Tracer

  @type status :: :running | :stopped | :reverted | :invalid | :out_of_gas | {:error, atom()}

  @type t :: %__MODULE__{
          pc: non_neg_integer(),
          stack: Stack.t(),
          memory: Memory.t(),
          db: Database.t(),
          env: Env.t(),
          substate: Substate.t(),
          contract: Contract.t(),
          call_stack: [CallFrame.t()],
          frame_return_offset: non_neg_integer(),
          frame_return_size: non_neg_integer(),
          is_static: boolean(),
          depth: non_neg_integer(),
          gas: non_neg_integer(),
          refund: non_neg_integer(),
          status: status(),
          return_data: binary(),
          code: binary(),
          tracer: Tracer.t() | nil
        }

  @enforce_keys [:code]
  defstruct pc: 0,
            stack: nil,
            memory: nil,
            db: nil,
            env: nil,
            substate: nil,
            contract: nil,
            call_stack: [],
            frame_return_offset: 0,
            frame_return_size: 0,
            is_static: false,
            depth: 0,
            gas: 1_000_000,
            refund: 0,
            status: :running,
            return_data: <<>>,
            code: <<>>,
            tracer: nil

  @doc """
  Creates a new machine state for executing the given bytecode.

  Includes EIP-2929/EIP-3651 access-list pre-warming so sender, recipient,
  precompiles, and `block.coinbase` start warm for address-access gas metering.

  ## Parameters
    - `code` — the raw EVM bytecode as an Elixir binary
    - `opts` — optional keyword list:
      - `:gas` — initial gas (default: 1,000,000)
      - `:db` — unified external database (default: empty in-memory DB)
      - `:storage` — legacy initial storage (default: empty, backward-compat)
      - `:tx` — transaction context (default: empty)
      - `:block` — block context (default: empty)
      - `:hardfork` — hardfork spec id (e.g. `:cancun`, `:berlin`; default: `:cancun`)
      - `:world_state` — legacy external account state (default: empty, backward-compat)
      - `:call_stack` — internal frame stack (default: `[]`)
      - `:frame_return_offset` — parent memory write-back offset (default: `0`)
      - `:frame_return_size` — parent memory write-back size (default: `0`)
      - `:is_static` — static context flag for this frame (default: `false`)
      - `:depth` — current call depth (default: `0`)
      - `:refund` — gas refund counter (default: `0`)
      - `:tracer` — optional `EEVM.Tracer` to record per-opcode trace (default: `nil`)

  ## Example

      iex> state = EEVM.Interpreter.MachineState.new(<<0x60, 0x01, 0x60, 0x02, 0x01>>)
      iex> state.pc
      0
  """
  @spec new(binary(), keyword()) :: t()
  def new(code, opts \\ []) do
    contract = Keyword.get(opts, :contract, Contract.new())
    tx = Keyword.get(opts, :tx, Transaction.new())
    block = Keyword.get(opts, :block, Block.new())
    config = Keyword.get(opts, :config, Config.new(Keyword.get(opts, :hardfork, :cancun)))

    substate =
      Substate.new(
        touched_addresses: Keyword.get(opts, :touched_addresses, MapSet.new()),
        accessed_addresses:
          Keyword.get(opts, :accessed_addresses, pre_warm_addresses(contract, tx, block, config)),
        accessed_storage_keys: Keyword.get(opts, :accessed_storage_keys, MapSet.new()),
        created_addresses: Keyword.get(opts, :created_addresses, MapSet.new()),
        original_storage: Keyword.get(opts, :original_storage, %{}),
        transient_storage: Keyword.get(opts, :transient_storage, %{}),
        logs: Keyword.get(opts, :logs, [])
      )

    %__MODULE__{
      code: code,
      stack: Stack.new(),
      memory: Memory.new(),
      db: init_db(opts, contract),
      env: Env.new(tx: tx, block: block, config: config),
      substate: substate,
      contract: contract,
      call_stack: Keyword.get(opts, :call_stack, []),
      frame_return_offset: Keyword.get(opts, :frame_return_offset, 0),
      frame_return_size: Keyword.get(opts, :frame_return_size, 0),
      is_static: Keyword.get(opts, :is_static, false),
      depth: Keyword.get(opts, :depth, 0),
      return_data: Keyword.get(opts, :return_data, <<>>),
      gas: Keyword.get(opts, :gas, 1_000_000),
      refund: Keyword.get(opts, :refund, 0),
      tracer: Keyword.get(opts, :tracer)
    }
  end

  # EIP-3651 (Shanghai): COINBASE is pre-warmed at tx start because many
  # contracts access the block producer address (e.g., builder/proposer payments),
  # and charging the first touch as cold penalizes a common access pattern.
  defp pre_warm_addresses(contract, tx, block, config) do
    MapSet.new()
    |> MapSet.put(contract.address)
    |> MapSet.put(contract.caller)
    |> MapSet.put(tx.origin)
    |> MapSet.put(block.coinbase)
    |> then(fn set ->
      Enum.reduce(Precompiles.precompile_addresses(config), set, &MapSet.put(&2, &1))
    end)
  end

  defp init_db(opts, contract) do
    case Keyword.fetch(opts, :db) do
      {:ok, db} ->
        db

      :error ->
        world_state = Keyword.get(opts, :world_state, EEVM.WorldState.new())
        storage = Keyword.get(opts, :storage, EEVM.Storage.new())

        InMemoryDB.new(
          accounts: world_state.accounts,
          storage: convert_storage(storage, contract.address)
        )
    end
  end

  defp convert_storage(%EEVM.Storage{slots: slots}, _address) when map_size(slots) == 0, do: %{}

  defp convert_storage(%EEVM.Storage{slots: slots}, address) do
    %{address => slots}
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

  @doc "Adds `amount` to the accumulated gas refund."
  @spec add_refund(t(), non_neg_integer()) :: t()
  def add_refund(state, amount), do: %{state | refund: state.refund + amount}

  @doc "Subtracts `amount` from refund, flooring at 0."
  @spec sub_refund(t(), non_neg_integer()) :: t()
  def sub_refund(state, amount), do: %{state | refund: max(state.refund - amount, 0)}

  @doc "Halts execution with the given status."
  @spec halt(t(), status()) :: t()
  def halt(state, status) do
    %{state | status: status}
  end

  @doc "Marks an address as touched for EIP-161 post-transaction cleanup."
  @spec touch_address(t(), non_neg_integer()) :: t()
  def touch_address(state, address) do
    sub = state.substate
    %{state | substate: %{sub | touched_addresses: MapSet.put(sub.touched_addresses, address)}}
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
