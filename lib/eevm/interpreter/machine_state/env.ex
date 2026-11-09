defmodule EEVM.Interpreter.MachineState.Env do
  @moduledoc """
  Per-call read-only execution environment.

  Bundles the fields that are set when a frame is constructed and
  never mutate during its lifetime:

  - `tx` — the originating transaction context (origin, gasprice, blob hashes…)
  - `block` — the block context (number, timestamp, coinbase, basefee…)
  - `config` — the active hardfork config (which EIPs are enabled, registered
    precompiles)
  - `instruction_table` — the hardfork's opcode dispatch table
    (`EEVM.Interpreter.InstructionTable`), resolved here once so the
    interpreter loop never re-checks the fork per opcode

  Child frames inherit the parent's env unchanged. Treating them as a single
  immutable record makes intent explicit at call sites — `state.env` is
  what you pass through, `state.frame` and `state.substate` are what you
  evolve.
  """

  alias EEVM.Config
  alias EEVM.Context.{Block, Transaction}
  alias EEVM.Interpreter.InstructionTable

  @type t :: %__MODULE__{
          tx: Transaction.t(),
          block: Block.t(),
          config: Config.t(),
          instruction_table: InstructionTable.t()
        }

  @enforce_keys [:tx, :block, :config, :instruction_table]
  defstruct [:tx, :block, :config, :instruction_table]

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    config = Keyword.get(opts, :config, Config.new())

    %__MODULE__{
      tx: Keyword.get(opts, :tx, Transaction.new()),
      block: Keyword.get(opts, :block, Block.new()),
      config: config,
      instruction_table: InstructionTable.for_spec(config.hardfork.spec_id)
    }
  end
end
