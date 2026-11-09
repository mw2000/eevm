defmodule EEVM.Interpreter do
  @moduledoc """
  The EVM interpreter — fetches, decodes, and dispatches opcodes in a loop.

  This is the core opcode-execution engine. It is invoked by `EEVM.Handler`
  (the transaction-level pipeline) and by system contracts that need to
  evaluate bytecode against an existing world state.

  Execution ends when a terminating opcode is reached (STOP, RETURN, REVERT,
  INVALID), the program counter advances past the end of the bytecode
  (implicit STOP), or gas runs out before the opcode can execute. INVALID
  (0xFE) is special-cased: its "base" gas cost is set to the entire
  remaining gas, draining it completely before the opcode runs.

  Opcode dispatch is data-driven via the frame's per-hardfork
  `EEVM.Interpreter.InstructionTable` (built from
  `EEVM.Interpreter.Instructions.Registry`); opcode modules own their
  semantics, and the interpreter only orchestrates.
  """

  alias EEVM.Database
  alias EEVM.HardforkConfig
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
  - `:authorization_refund` — EIP-7702 refund earned before execution; it is
    added to the refund counter even when execution fails

  Returns the final `MachineState` after execution completes, with the
  transaction-end steps of `finalize/3` applied.
  """

  @spec run(binary(), keyword()) :: MachineState.t()
  def run(code, opts \\ []) do
    code
    |> MachineState.new(opts)
    |> run_loop()
    |> finalize(Keyword.get(opts, :gas, 1_000_000), Keyword.get(opts, :authorization_refund, 0))
  end

  @doc """
  Applies the transaction-end steps to a halted top-level state: deletes the
  accounts that SELFDESTRUCTed and touched empty accounts (EIP-161), then settles the refund counter into
  `frame.gas` and resets the counter to 0.

  The refund is capped at a fraction of the gas used by the whole
  transaction: 1/5 from London (EIP-3529), 1/2 before. When `env.tx.gas_limit`
  is set, gas used counts from it and so includes intrinsic gas; otherwise it
  counts from `initial_gas`. The execution refund counts only when execution
  succeeded; `authorization_refund` (EIP-7702) always counts. From Prague the
  gas charged after the refund is floored at the EIP-7623 calldata cost.

  `run/2` calls this itself. Callers that charge more gas after execution
  ends, such as the code deposit of a CREATE transaction, call `run_loop/1`,
  charge that gas, then call this, so the cap counts it.
  """
  @spec finalize(MachineState.t(), non_neg_integer(), non_neg_integer()) :: MachineState.t()
  def finalize(%MachineState{} = state, initial_gas, authorization_refund \\ 0) do
    state
    |> delete_selfdestructed_accounts()
    |> cleanup_touched_empty_accounts()
    |> apply_refund(initial_gas, authorization_refund)
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
        # Running off the end of the code is an implicit STOP: empty output.
        state
        |> MachineState.update_frame(&%{&1 | return_data: <<>>})
        |> MachineState.halt(:stopped)

      opcode ->
        instruction = elem(state.env.instruction_table, opcode)
        static_cost = if opcode == 0xFE, do: state.frame.gas, else: elem(instruction, 0)
        traced_state = trace_opcode(state, opcode, static_cost)

        case MachineState.consume_gas(traced_state, static_cost) do
          {:ok, state_after_gas} ->
            case execute_opcode(instruction, state_after_gas) do
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
    state_with_restored_refund =
      MachineState.update_frame(state, &%{&1 | refund: parent.refund})

    {:ok, resumed_state} = MachineState.pop_frame(state_with_restored_refund)
    run_loop(resumed_state)
  end

  def run_loop(%MachineState{status: status, call_stack: [_ | _]} = state)
      when status in [:stopped, :invalid, :out_of_gas] do
    {:ok, resumed_state} = MachineState.pop_frame(state)
    run_loop(resumed_state)
  end

  def run_loop(state), do: state

  # Settles the transaction's refund counter (Prague `process_transaction`):
  # the EIP-7702 authorization refund always counts, the execution refund only
  # when the call succeeded. The cap applies to total gas used, including
  # intrinsic gas, when a transaction gas limit is known. The EIP-7623 floor
  # applies whether or not execution succeeded.
  defp apply_refund(%MachineState{status: status} = state, initial_gas, authorization_refund) do
    tx_gas_limit = state.env.tx.gas_limit
    gas_used = if(tx_gas_limit > 0, do: tx_gas_limit, else: initial_gas) - state.frame.gas
    execution_refund = if status == :stopped, do: state.frame.refund, else: 0

    # EIP-3529 (London+): cap refunds at 1/5 of gas used.
    # Pre-London: cap was 1/2 of gas used.
    refund_cap_divisor =
      if HardforkConfig.enabled?(state.env.config.hardfork, :eip_3529), do: 5, else: 2

    effective_refund =
      min(authorization_refund + execution_refund, div(gas_used, refund_cap_divisor))

    refunded_gas = state.frame.gas + effective_refund

    calldata_floor_gas =
      IntrinsicGas.calldata_floor_gas_cost(state.env.tx, state.env.config.hardfork)

    gas_after_floor =
      if calldata_floor_gas > 0 and tx_gas_limit > 0 do
        min(refunded_gas, max(tx_gas_limit - calldata_floor_gas, 0))
      else
        refunded_gas
      end

    MachineState.update_frame(state, &%{&1 | gas: gas_after_floor, refund: 0})
  end

  # SELFDESTRUCT only marks an account; it disappears, storage included, when
  # the transaction ends (EIP-6780 keeps this for same-transaction contracts).
  defp delete_selfdestructed_accounts(%MachineState{status: :stopped} = state) do
    db =
      Enum.reduce(state.substate.selfdestructed_addresses, state.db, fn address, db_acc ->
        Database.delete_account(db_acc, address)
      end)

    %{state | db: db}
  end

  defp delete_selfdestructed_accounts(state), do: state

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

  # Dispatch an opcode to the module its instruction-table entry names (see
  # `EEVM.Interpreter.InstructionTable`). Before the module runs, the stack
  # bounds are checked once here: fewer than the entry's minimum depth is a
  # stack underflow, and above its maximum depth the opcode would end with
  # more than 1024 items, a stack overflow (Yellow Paper §9.4.2). Opcode
  # modules can therefore push without handling `{:error, :stack_overflow}`.
  # Inside a STATICCALL frame (`frame.is_static`), state-mutating opcodes
  # (SSTORE, TSTORE, LOG0..4, CREATE, CREATE2, SELFDESTRUCT) are an
  # exceptional halt (EIP-214). Bytes the active fork does not define
  # dispatch as INVALID.

  defp execute_opcode({_gas, module, opcode, min_depth, max_depth, state_mutating?}, state) do
    depth = Stack.depth(state.frame.stack)

    cond do
      depth < min_depth -> {:error, :stack_underflow, state}
      depth > max_depth -> {:error, :stack_overflow, state}
      state_mutating? and state.frame.is_static -> {:error, :static_state_modification, state}
      true -> module.execute(opcode, state)
    end
  end

  # Trace bookkeeping is a no-op when no tracer is attached — one pattern match,
  # one return. All helpers below keep this fast path.

  defp trace_opcode(%MachineState{tracer: nil} = state, _opcode, _static_cost), do: state

  defp trace_opcode(%MachineState{tracer: tracer, frame: frame} = state, opcode, static_cost) do
    step = %TraceStep{
      pc: frame.pc,
      op: Tracer.op_name(opcode),
      op_byte: opcode,
      gas_remaining: frame.gas,
      gas_cost: static_cost,
      stack: Stack.to_list(frame.stack),
      memory_size: Memory.size(frame.memory),
      depth: frame.depth,
      refund: frame.refund,
      return_data: frame.return_data,
      error: nil
    }

    %{state | tracer: Tracer.record(tracer, step)}
  end

  defp annotate_last_error(%MachineState{tracer: nil} = state, _reason), do: state

  defp annotate_last_error(%MachineState{tracer: tracer} = state, reason) do
    %{state | tracer: Tracer.set_last_error(tracer, reason)}
  end
end
