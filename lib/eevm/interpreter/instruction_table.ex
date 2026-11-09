defmodule EEVM.Interpreter.InstructionTable do
  @moduledoc """
  Per-hardfork opcode dispatch tables, built at compile time.

  A table is a 256-element tuple indexed by opcode byte. Each entry is
  `{static_gas, module, dispatch_opcode, min_depth, max_depth, state_mutating?}`:

  - `static_gas` — the cost `EEVM.Interpreter` charges before dispatch,
    from `EEVM.Gas.Static` for that hardfork
  - `module` and `dispatch_opcode` — the interpreter calls
    `module.execute(dispatch_opcode, state)`
  - `min_depth` / `max_depth` — the stack depths the opcode can run at: it
    pops the Registry's `:inputs`, and must not leave more than 1024 items
  - `state_mutating?` — whether the opcode must halt inside a STATICCALL frame

  Bytes the hardfork does not define — unassigned bytes, and opcodes whose
  activating EIP (the Registry's `:eip` field) is not yet enabled — get the
  INVALID (0xFE) entry, dispatch opcode included, so they halt exactly like
  INVALID even when their module implements them on later forks.

  `EEVM.Interpreter.MachineState.Env` resolves the table once per frame from
  the active hardfork, and the interpreter indexes it with `elem/2`, so the
  per-opcode path never checks which fork is active.
  """

  alias EEVM.Gas.Static
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.Instructions.Registry
  alias EEVM.Interpreter.Stack

  @type entry ::
          {non_neg_integer(), module(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           boolean()}
  @type t :: tuple()

  @invalid 0xFE

  @doc "Returns the dispatch table for `spec_id`."
  @spec for_spec(HardforkConfig.spec_id()) :: t()
  def for_spec(spec_id)

  for spec_id <- HardforkConfig.all_spec_ids() do
    hardfork = HardforkConfig.new(spec_id)

    entry = fn opcode, info ->
      {Static.static_cost(opcode, spec_id), info.module, opcode, info.inputs,
       Stack.max_depth() - info.outputs + info.inputs, Map.get(info, :state_mutating, false)}
    end

    {:ok, invalid_info} = Registry.info(@invalid)
    invalid_entry = entry.(@invalid, invalid_info)

    table =
      for opcode <- 0x00..0xFF do
        case Registry.info(opcode) do
          {:ok, %{eip: eip} = info} ->
            if HardforkConfig.enabled?(hardfork, eip),
              do: entry.(opcode, info),
              else: invalid_entry

          {:ok, info} ->
            entry.(opcode, info)

          {:error, :unknown_opcode} ->
            invalid_entry
        end
      end

    def for_spec(unquote(spec_id)), do: unquote(Macro.escape(List.to_tuple(table)))
  end
end
