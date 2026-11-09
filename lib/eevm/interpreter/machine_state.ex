defmodule EEVM.Interpreter.MachineState do
  @moduledoc """
  The EVM machine state — the envelope that holds everything that survives
  a single opcode step.

  ## Anatomy

  - **frame** (`Frame.t()`) — the active per-call execution context: pc,
    stack, memory, gas, refund, code, return_data, contract, depth,
    is_static.
  - **env** (`Env.t()`) — read-only execution environment for this call:
    tx, block, hardfork config.
  - **substate** (`Substate.t()`) — transaction-scoped accumulators:
    touched / accessed / created / original / transient / logs.
  - **db** — unified world-state backend (accounts + storage).
  - **status** — `:running | :stopped | :reverted | :invalid | :out_of_gas`
    or `{:error, atom()}`.
  - **tracer** — optional opcode-level trace recorder.

  Frame, env, and substate isolate the three lifecycles cleanly: frame is
  per-call mutable, env is per-call immutable, substate is transaction-scoped.
  """

  alias EEVM.Config
  alias EEVM.Context.{Block, Contract, Transaction}
  alias EEVM.Database
  alias EEVM.Database.InMemory, as: InMemoryDB
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.MachineState.{Env, Frame, Substate}
  alias EEVM.Interpreter.{Memory, Stack}
  alias EEVM.Precompiles
  alias EEVM.Tracer

  @type status :: :running | :stopped | :reverted | :invalid | :out_of_gas | {:error, atom()}

  @type t :: %__MODULE__{
          frame: Frame.t(),
          env: Env.t(),
          substate: Substate.t(),
          db: Database.t(),
          status: status(),
          tracer: Tracer.t() | nil
        }

  @enforce_keys [:frame]
  defstruct frame: nil,
            env: nil,
            substate: nil,
            db: nil,
            status: :running,
            tracer: nil

  @doc """
  Creates a new machine state for executing the given bytecode.

  Includes EIP-2929 access-list pre-warming so sender, recipient, precompiles,
  and from Shanghai (EIP-3651) `block.coinbase` start warm for address-access
  gas metering.

  ## Parameters
    - `code` — the raw EVM bytecode as an Elixir binary
    - `opts` — optional keyword list:
      - `:gas` — initial gas (default: 1,000,000)
      - `:db` — unified external database (default: empty in-memory DB)
      - `:tx` — transaction context (default: empty)
      - `:block` — block context (default: empty)
      - `:hardfork` — hardfork spec id (e.g. `:cancun`, `:berlin`; default: `:cancun`)
      - `:is_static` — static context flag for this frame (default: `false`)
      - `:depth` — current call depth (default: `0`)
      - `:refund` — gas refund counter (default: `0`)
      - `:tracer` — optional `EEVM.Tracer` to record per-opcode trace (default: `nil`)

  ## Example

      iex> state = EEVM.Interpreter.MachineState.new(<<0x60, 0x01, 0x60, 0x02, 0x01>>)
      iex> state.frame.pc
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
        selfdestructed_addresses: Keyword.get(opts, :selfdestructed_addresses, MapSet.new()),
        original_storage: Keyword.get(opts, :original_storage, %{}),
        transient_storage: Keyword.get(opts, :transient_storage, %{}),
        logs: Keyword.get(opts, :logs, [])
      )

    frame = %Frame{
      code: code,
      stack: Stack.new(),
      memory: Memory.new(),
      contract: contract,
      is_static: Keyword.get(opts, :is_static, false),
      depth: Keyword.get(opts, :depth, 0),
      return_data: Keyword.get(opts, :return_data, <<>>),
      gas: Keyword.get(opts, :gas, 1_000_000),
      refund: Keyword.get(opts, :refund, 0)
    }

    %__MODULE__{
      frame: frame,
      env: Env.new(tx: tx, block: block, config: config),
      substate: substate,
      db: Keyword.get_lazy(opts, :db, &InMemoryDB.new/0),
      tracer: Keyword.get(opts, :tracer)
    }
  end

  # EIP-3651 (Shanghai): COINBASE is pre-warmed at tx start because many
  # contracts access the block producer address (e.g., builder/proposer payments),
  # and charging the first touch as cold penalizes a common access pattern.
  defp pre_warm_addresses(contract, tx, block, config) do
    addresses =
      MapSet.new()
      |> MapSet.put(contract.address)
      |> MapSet.put(contract.caller)
      |> MapSet.put(tx.origin)
      |> then(fn set ->
        Enum.reduce(Precompiles.precompile_addresses(config), set, &MapSet.put(&2, &1))
      end)

    if HardforkConfig.enabled?(config.hardfork, :eip_3651),
      do: MapSet.put(addresses, block.coinbase),
      else: addresses
  end

  @doc "Returns the opcode byte at the current program counter, or nil if past end."
  @spec current_opcode(t()) :: non_neg_integer() | nil
  def current_opcode(%__MODULE__{frame: %Frame{pc: pc, code: code}}) when pc < byte_size(code) do
    :binary.at(code, pc)
  end

  def current_opcode(_state), do: nil

  @doc """
  Reads `n` bytes from the code starting at `offset`.

  Used by PUSH instructions to read their immediate data.
  """
  @spec read_code(t(), non_neg_integer(), non_neg_integer()) :: binary()
  def read_code(%__MODULE__{frame: %Frame{code: code}}, offset, n) do
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
    update_frame(state, &%{&1 | pc: &1.pc + n})
  end

  @spec current_depth(t()) :: non_neg_integer()
  def current_depth(%__MODULE__{frame: %Frame{depth: depth}}), do: depth

  @doc """
  Replaces the active frame using the given function.

  Convenience for callers that want to update one or more per-frame fields
  without re-spelling the nested struct update.
  """
  @spec update_frame(t(), (Frame.t() -> Frame.t())) :: t()
  def update_frame(%__MODULE__{frame: frame} = state, fun) do
    %{state | frame: fun.(frame)}
  end

  @doc """
  Deducts gas from the active frame.

  Returns `{:ok, updated_state}` if sufficient gas remains, or
  `{:error, :out_of_gas, state}` if the gas would go negative.
  """
  @spec consume_gas(t(), non_neg_integer()) :: {:ok, t()} | {:error, :out_of_gas, t()}
  def consume_gas(%__MODULE__{frame: %Frame{gas: gas}} = state, cost) when cost <= gas do
    {:ok, update_frame(state, &%{&1 | gas: &1.gas - cost})}
  end

  def consume_gas(state, _cost) do
    {:error, :out_of_gas, halt(state, :out_of_gas)}
  end

  @doc "Returns the gas remaining."
  @spec gas_remaining(t()) :: non_neg_integer()
  def gas_remaining(%__MODULE__{frame: %Frame{gas: gas}}), do: gas

  @doc "Adds `amount` to the accumulated gas refund."
  @spec add_refund(t(), non_neg_integer()) :: t()
  def add_refund(state, amount), do: update_frame(state, &%{&1 | refund: &1.refund + amount})

  @doc """
  Subtracts `amount` from the accumulated gas refund.

  The counter is frame-local (a child frame starts at 0 and its counter is
  added to the parent's on success), so it may go negative: a child can undo
  a refund that its parent earned, e.g. by restoring a slot the parent cleared.
  """
  @spec sub_refund(t(), non_neg_integer()) :: t()
  def sub_refund(state, amount), do: update_frame(state, &%{&1 | refund: &1.refund - amount})

  @doc """
  Halts execution with the given status.

  `:stopped` and `:reverted` keep the frame's remaining gas. Exceptional halts
  (`:invalid`, `:out_of_gas`, `{:error, reason}`) consume all of it and
  produce no return data.
  """
  @spec halt(t(), status()) :: t()
  def halt(state, status) when status in [:running, :stopped, :reverted] do
    %{state | status: status}
  end

  def halt(state, status) do
    %{update_frame(state, &%{&1 | gas: 0, return_data: <<>>}) | status: status}
  end

  @doc "Marks an address as touched for EIP-161 post-transaction cleanup."
  @spec touch_address(t(), non_neg_integer()) :: t()
  def touch_address(state, address) do
    sub = state.substate
    %{state | substate: %{sub | touched_addresses: MapSet.put(sub.touched_addresses, address)}}
  end
end
