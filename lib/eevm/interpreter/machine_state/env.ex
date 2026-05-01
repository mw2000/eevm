defmodule EEVM.Interpreter.MachineState.Env do
  @moduledoc """
  Per-call read-only execution environment.

  Bundles the three fields that are set when a frame is constructed and
  never mutate during its lifetime:

  - `tx` — the originating transaction context (origin, gasprice, blob hashes…)
  - `block` — the block context (number, timestamp, coinbase, basefee…)
  - `config` — the active hardfork config (which EIPs are enabled, registered
    precompiles)

  Child frames inherit the parent's env unchanged. Treating them as a single
  immutable record makes intent explicit at call sites — `state.env` is
  what you pass through, `state.frame` and `state.substate` are what you
  evolve.
  """

  alias EEVM.Config
  alias EEVM.Context.{Block, Transaction}

  @type t :: %__MODULE__{
          tx: Transaction.t(),
          block: Block.t(),
          config: Config.t()
        }

  @enforce_keys [:tx, :block, :config]
  defstruct [:tx, :block, :config]

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      tx: Keyword.get(opts, :tx, Transaction.new()),
      block: Keyword.get(opts, :block, Block.new()),
      config: Keyword.get(opts, :config, Config.new())
    }
  end
end
