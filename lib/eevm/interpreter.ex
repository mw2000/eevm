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

  import Bitwise, only: [<<<: 2]

  alias EEVM.Database
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.Instructions.{Helpers, Registry}
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
  The main execution loop. Runs the active frame until it halts.

  Any status but `:running` means the frame has already halted, and the state
  is returned as-is. It runs one frame: CALL and CREATE run each child frame in
  a nested call and merge the result into the parent
  (`EEVM.Interpreter.Journal`). It is public for those callers and the
  transaction handler; it is not part of the public API — use `run/2`.
  """
  @spec run_loop(MachineState.t()) :: MachineState.t()
  def run_loop(%MachineState{status: :running, frame: frame} = state) do
    %Stack{elements: stack, size: depth} = frame.stack
    loop(state, frame.code, state.env.instruction_table, frame.pc, frame.gas, stack, depth)
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

  # EIP-161 (Spurious Dragon): empty accounts touched by a successful
  # transaction are deleted.
  defp cleanup_touched_empty_accounts(%MachineState{status: :stopped} = state) do
    if HardforkConfig.enabled?(state.env.config.hardfork, :eip_161),
      do: delete_touched_empty_accounts(state),
      else: state
  end

  defp cleanup_touched_empty_accounts(state), do: state

  defp delete_touched_empty_accounts(state) do
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

  # ## The register loop
  #
  # `loop/7` keeps what changes on almost every opcode in its own arguments
  # instead of in the `MachineState`: `pc`, `gas`, and `stack` (a list, top
  # first) with its `depth`, plus the frame's `code` and the fork's instruction
  # `table`, so the hot path never reads them out of a struct.
  #
  # While it runs, `state.frame`'s pc, gas, and stack are stale; every other
  # field (memory, refund, return data, contract, ...) is current. `:stack` and
  # `:control` opcodes run on the registers alone. A `:state` opcode, a halt, or
  # the end of the frame first writes the registers back (`sync/5`), so opcode
  # modules and callers only ever see a complete `MachineState`. This keeps the
  # frame and machine-state structs from being rebuilt on every opcode (#193).
  #
  # Each opcode is checked once, from its instruction-table entry (see
  # `EEVM.Interpreter.InstructionTable`), before it runs: static gas, then the
  # stack bounds. Fewer items than the entry's minimum depth is a stack
  # underflow; above its maximum depth the opcode would end with more than 1024
  # items, a stack overflow (Yellow Paper §9.4.2). Opcodes can therefore assume
  # their inputs are there and push freely. Bytes the active fork does not
  # define have the INVALID entry.

  defp loop(state, code, table, pc, gas, stack, depth) do
    case code do
      <<_::binary-size(pc), opcode, _::binary>> ->
        {cost, kind, _module, op, min_depth, max_depth, _mutating?} = entry = elem(table, opcode)
        state = trace_opcode(state, opcode, cost, pc, gas, stack)

        cond do
          cost > gas -> halt(state, :out_of_gas, pc, gas, stack, depth)
          depth < min_depth -> halt(state, :stack_underflow, pc, gas, stack, depth)
          depth > max_depth -> halt(state, :stack_overflow, pc, gas, stack, depth)
          kind == :state -> run_state_op(entry, sync(state, pc, gas - cost, stack, depth))
          true -> step(op, state, code, table, pc, gas - cost, stack, depth)
        end

      _ ->
        # Running off the end of the code is an implicit STOP: empty output.
        state
        |> sync(pc, gas, stack, depth)
        |> MachineState.update_frame(&%{&1 | return_data: <<>>})
        |> MachineState.halt(:stopped)
    end
  end

  # A `:state` opcode runs on the whole machine state; the loop then resumes
  # from the frame it returns. Inside a STATICCALL frame, state-mutating
  # opcodes (SSTORE, TSTORE, LOG0..4, CREATE, CREATE2, SELFDESTRUCT) are an
  # exceptional halt (EIP-214).
  defp run_state_op({_cost, _kind, module, op, _min, _max, state_mutating?}, state) do
    result =
      if state_mutating? and state.frame.is_static,
        do: {:error, :static_state_modification, state},
        else: module.execute(op, state)

    case result do
      {:ok, state} ->
        run_loop(state)

      {:error, :out_of_gas, state} ->
        annotate_last_error(state, :out_of_gas)

      {:error, reason, state} ->
        state |> MachineState.halt({:error, reason}) |> annotate_last_error(reason)
    end
  end

  # `:stack` opcodes: one clause per opcode, generated from the Registry, so the
  # call to its `stack_op/2` and the change in stack depth are compile-time
  # constants.
  for opcode <- 0..255, {:ok, %{kind: :stack} = info} <- [Registry.info(opcode)] do
    defp step(unquote(opcode), state, code, table, pc, gas, stack, depth) do
      stack = unquote(info.module).stack_op(unquote(opcode), stack)
      loop(state, code, table, pc + 1, gas, stack, depth + unquote(info.outputs - info.inputs))
    end
  end

  # `:control` opcodes read or move the loop's own registers.

  # PUSH0 (EIP-3855) pushes 0 without reading any code.
  defp step(0x5F, state, code, table, pc, gas, stack, depth),
    do: loop(state, code, table, pc + 1, gas, [0 | stack], depth + 1)

  # PUSH1–PUSH32 push the n code bytes after the opcode as a big-endian integer.
  for n <- 1..32 do
    defp step(unquote(0x5F + n), state, code, table, pc, gas, stack, depth) do
      value = push_data(code, pc + 1, unquote(n))
      loop(state, code, table, pc + unquote(n + 1), gas, [value | stack], depth + 1)
    end
  end

  defp step(0x56, state, code, table, pc, gas, [dest | stack], depth),
    do: jump(state, code, table, pc, gas, stack, depth - 1, dest)

  defp step(0x57, state, code, table, pc, gas, [_dest, 0 | stack], depth),
    do: loop(state, code, table, pc + 1, gas, stack, depth - 2)

  defp step(0x57, state, code, table, pc, gas, [dest, _condition | stack], depth),
    do: jump(state, code, table, pc, gas, stack, depth - 2, dest)

  defp step(0x58, state, code, table, pc, gas, stack, depth),
    do: loop(state, code, table, pc + 1, gas, [pc | stack], depth + 1)

  # GAS pushes the gas left after its own cost.
  defp step(0x5A, state, code, table, pc, gas, stack, depth),
    do: loop(state, code, table, pc + 1, gas, [gas | stack], depth + 1)

  defp step(0x5B, state, code, table, pc, gas, stack, depth),
    do: loop(state, code, table, pc + 1, gas, stack, depth)

  # Code reads as zeros past its end, so a PUSH cut short by the end of the
  # code fills its missing low-order bytes with zeros.
  defp push_data(code, offset, n) do
    case code do
      <<_::binary-size(offset), value::unsigned-size(n)-unit(8), _::binary>> ->
        value

      <<_::binary-size(offset), available::binary>> ->
        :binary.decode_unsigned(available) <<< (8 * (n - byte_size(available)))
    end
  end

  # JUMP and JUMPI may only land on a JUMPDEST opcode (Yellow Paper §9.4.3).
  # `Helpers.check_jumpdest/2` keeps the code's JUMPDEST map in `frame.jumpdests`,
  # which the registers do not shadow, so it survives into child frames and halts.
  defp jump(state, code, table, pc, gas, stack, depth, dest) do
    case Helpers.check_jumpdest(state, dest) do
      {:ok, state} -> loop(state, code, table, dest, gas, stack, depth)
      {:error, reason, state} -> halt(state, reason, pc, gas, stack, depth)
    end
  end

  # Writes the registers back into the frame.
  defp sync(%MachineState{frame: frame} = state, pc, gas, stack, depth) do
    %{state | frame: %{frame | pc: pc, gas: gas, stack: %Stack{elements: stack, size: depth}}}
  end

  # An exceptional halt: `MachineState.halt/2` burns the frame's remaining gas.
  defp halt(state, reason, pc, gas, stack, depth) do
    state
    |> sync(pc, gas, stack, depth)
    |> MachineState.halt(halt_status(reason))
    |> annotate_last_error(reason)
  end

  defp halt_status(:out_of_gas), do: :out_of_gas
  defp halt_status(reason), do: {:error, reason}

  # Trace bookkeeping is a no-op when no tracer is attached — one pattern match,
  # one return. All helpers below keep this fast path.

  defp trace_opcode(%MachineState{tracer: nil} = state, _opcode, _cost, _pc, _gas, _stack),
    do: state

  defp trace_opcode(
         %MachineState{tracer: tracer, frame: frame} = state,
         opcode,
         cost,
         pc,
         gas,
         stack
       ) do
    step = %TraceStep{
      pc: pc,
      op: Tracer.op_name(opcode),
      op_byte: opcode,
      gas_remaining: gas,
      # INVALID consumes all remaining gas.
      gas_cost: if(opcode == 0xFE, do: gas, else: cost),
      stack: stack,
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
