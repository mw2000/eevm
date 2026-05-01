defmodule EEVM.Interpreter do
  @moduledoc """
  The EVM interpreter — fetches, decodes, and dispatches opcodes in a loop.

  This is the core opcode-execution engine. It is invoked by the
  `EEVM.Handler` (the transaction-level pipeline) and by system
  contracts that need to evaluate bytecode against an existing world state.

  ## EVM Concepts

  The executor implements the EVM's fetch-decode-execute cycle:

  1. **Fetch**: Read one byte from bytecode at the current program counter.
  2. **Decode**: Look up the base gas cost and identify which opcode module
     handles this byte.
  3. **Execute**: Deduct base gas, delegate to the opcode module, and loop.

  Execution ends when:
  - A terminating opcode is reached (STOP, RETURN, REVERT, INVALID).
  - The program counter advances past the end of the bytecode (implicit STOP).
  - Gas runs out before the opcode can execute.

  INVALID (0xFE) is special-cased: its "base" gas cost is set to the entire
  remaining gas, draining it completely before the opcode runs.

  ## Elixir Learning Notes

  - `run_loop/1` is tail-recursive — Elixir optimizes tail calls, so the loop
    runs in constant stack space even for long-running contracts.
  - The three `run_loop/1` clauses use pattern matching on `status` to cleanly
    separate running, halted, and out-of-gas states without any conditionals.
  - Opcode dispatch is data-driven: `EEVM.Interpreter.Instructions.Registry`
    maps each opcode to its implementing module, and `execute_opcode/2` is a
    single registry lookup rather than a hand-maintained case table.
  - Separation of concerns: the executor only orchestrates; opcode modules own
    their semantics.
  """

  alias EEVM.Database
  alias EEVM.Gas.Static
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.Instructions.Registry
  alias EEVM.Interpreter.{MachineState, Memory, Stack}
  alias EEVM.Tracer
  alias EEVM.Tracer.TraceStep
  alias EEVM.Transaction.IntrinsicGas

  @doc """
  Creates a `MachineState` from bytecode and options, then runs the execution loop.

  ## Options

  - `:gas` — initial gas limit (default: 1_000_000)
  - `:value` — ETH value sent with the call, in wei
  - `:code` — contract bytecode (usually the same as the first argument)
  - `:calldata` — ABI-encoded input data for the call
  - `:caller` — address of the account initiating this call
  - `:origin` — address of the original transaction signer

  Returns the final `MachineState` after execution completes.
  """

  @spec run(binary(), keyword()) :: MachineState.t()
  def run(code, opts \\ []) do
    initial_gas = Keyword.get(opts, :gas, 1_000_000)

    final_state =
      code
      |> MachineState.new(opts)
      |> run_loop()
      |> cleanup_touched_empty_accounts()

    apply_refund(final_state, initial_gas)
  end

  @doc """
  The main execution loop. Runs until execution terminates.

  Three clauses handle the three possible states:

  1. `status: :running` — fetch the current opcode, deduct static gas, delegate
     to `execute_opcode/2`, and recurse.
  2. Any non-running status (`:stopped`, `:returned`, `:reverted`, `:invalid`,
     `{:error, reason}`) — the machine has halted; return as-is.
  3. Out-of-gas during static cost deduction — the halted state is returned
     directly from `MachineState.consume_gas/2`.

  This function is public because it is called recursively by itself. It is
  the internal execution engine and not part of the public API — use `run/2`.
  """

  @spec run_loop(MachineState.t()) :: MachineState.t()
  def run_loop(%MachineState{status: :running} = state) do
    case MachineState.current_opcode(state) do
      nil ->
        MachineState.halt(state, :stopped)

      opcode ->
        static_cost = if opcode == 0xFE, do: state.gas, else: Static.static_cost(opcode)
        traced_state = trace_opcode(state, opcode, static_cost)

        case MachineState.consume_gas(traced_state, static_cost) do
          {:ok, state_after_gas} ->
            case execute_opcode(opcode, state_after_gas) do
              {:ok, new_state} ->
                run_loop(new_state)

              {:error, :out_of_gas, halted_state} ->
                annotate_last_error(halted_state, :out_of_gas)

              {:error, reason, error_state} ->
                error_state
                |> MachineState.halt({:error, reason})
                |> annotate_last_error(reason)
            end

          {:error, :out_of_gas, halted_state} ->
            annotate_last_error(halted_state, :out_of_gas)
        end
    end
  end

  def run_loop(%MachineState{status: :reverted, call_stack: [parent | _]} = state) do
    state_with_restored_refund = %{state | refund: parent.refund}
    {:ok, resumed_state} = MachineState.pop_frame(state_with_restored_refund)
    run_loop(resumed_state)
  end

  def run_loop(%MachineState{status: status, call_stack: [_ | _]} = state)
      when status in [:stopped, :invalid, :out_of_gas] do
    {:ok, resumed_state} = MachineState.pop_frame(state)
    run_loop(resumed_state)
  end

  def run_loop(state), do: state

  defp apply_refund(%MachineState{status: status} = state, _initial_gas)
       when status in [:reverted, :out_of_gas, :invalid] do
    %{state | refund: 0}
  end

  defp apply_refund(%MachineState{} = state, initial_gas) do
    gas_used = initial_gas - state.gas
    # EIP-3529 (London+): cap refunds at 1/5 of gas used.
    # Pre-London: cap was 1/2 of gas used.
    refund_cap_divisor =
      if HardforkConfig.enabled?(state.env.config.hardfork, :eip_3529), do: 5, else: 2

    effective_refund = min(state.refund, div(gas_used, refund_cap_divisor))

    refunded_gas = state.gas + effective_refund

    calldata_floor_gas =
      IntrinsicGas.calldata_floor_gas_cost(state.env.tx, state.env.config.hardfork)

    gas_after_floor =
      if calldata_floor_gas > 0 and state.env.tx.gas_limit > 0 do
        min(refunded_gas, max(state.env.tx.gas_limit - calldata_floor_gas, 0))
      else
        refunded_gas
      end

    %{state | gas: gas_after_floor, refund: 0}
  end

  defp cleanup_touched_empty_accounts(%MachineState{status: :stopped} = state) do
    cleaned_db =
      Enum.reduce(state.substate.touched_addresses, state.db, fn address, db_acc ->
        if Database.account_empty?(db_acc, address) do
          Database.delete_account(db_acc, address)
        else
          db_acc
        end
      end)

    %{state | db: cleaned_db}
  end

  defp cleanup_touched_empty_accounts(state), do: state

  # Dispatch an opcode byte to its implementing module via the Registry.
  #
  # The Registry maps each opcode to a `:module` (the `Instructions.*` module
  # whose `execute/2` handles it) and a `:state_mutating` flag. Inside a
  # STATICCALL frame (`state.is_static`), state-mutating opcodes (SSTORE,
  # TSTORE, LOG0..4, CREATE, CREATE2, SELFDESTRUCT) halt with `:reverted`
  # before reaching the module. Unknown opcodes halt as `:invalid`.

  defp execute_opcode(opcode, state) do
    case Registry.info(opcode) do
      {:ok, %{state_mutating: true}} when state.is_static ->
        {:ok, MachineState.halt(state, :reverted)}

      {:ok, %{module: module}} ->
        module.execute(opcode, state)

      {:error, :unknown_opcode} ->
        {:ok, MachineState.halt(state, :invalid)}
    end
  end

  # Trace bookkeeping is a no-op when no tracer is attached — one pattern match,
  # one return. All helpers below keep this fast path.

  defp trace_opcode(%MachineState{tracer: nil} = state, _opcode, _static_cost), do: state

  defp trace_opcode(%MachineState{tracer: tracer} = state, opcode, static_cost) do
    step = %TraceStep{
      pc: state.pc,
      op: Tracer.op_name(opcode),
      op_byte: opcode,
      gas_remaining: state.gas,
      gas_cost: static_cost,
      stack: Stack.to_list(state.stack),
      memory_size: Memory.size(state.memory),
      depth: state.depth,
      refund: state.refund,
      return_data: state.return_data,
      error: nil
    }

    %{state | tracer: Tracer.record(tracer, step)}
  end

  defp annotate_last_error(%MachineState{tracer: nil} = state, _reason), do: state

  defp annotate_last_error(%MachineState{tracer: tracer} = state, reason) do
    %{state | tracer: Tracer.set_last_error(tracer, reason)}
  end
end
