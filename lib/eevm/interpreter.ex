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
  alias EEVM.Interpreter.Instructions.Registry
  alias EEVM.Interpreter.{InstructionTable, MachineState, Memory, Stack}
  alias EEVM.Tracer
  alias EEVM.Tracer.TraceStep
  alias EEVM.Transaction.IntrinsicGas

  # The `gas` register holds at most `@gas_window`, the largest integer the BEAM
  # keeps unboxed on 64-bit machines; any gas above it waits in `frame.gas`. A
  # larger integer lives on the heap, so subtracting each opcode's cost from it
  # would allocate on every opcode, and state tests routinely give a
  # transaction 2^63 - 1 gas (loopMul ran 1.65x slower). The register is
  # refilled from `frame.gas` when it runs out (`out_of_gas/5`), so opcodes
  # never see the window.
  @gas_window (1 <<< 59) - 1

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
  def run_loop(%MachineState{status: :running, frame: %{program: nil}} = state),
    do: state |> load_program() |> run_loop()

  def run_loop(%MachineState{status: :running, frame: frame} = state) do
    %Stack{elements: stack, size: depth} = frame.stack
    gas = min(frame.gas, @gas_window)
    state = %{state | frame: %{frame | gas: frame.gas - gas}}
    loop(state, frame.program, frame.pc, gas, stack, depth)
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
  # `loop/6` keeps what changes on almost every opcode in its own arguments
  # instead of in the `MachineState`: `pc`, `gas`, and `stack` (a list, top
  # first) with its `depth`, plus the frame's decoded `program`, so the hot
  # path never reads them out of a struct.
  #
  # While it runs, `state.frame`'s pc and stack are stale and `frame.gas` holds
  # only the gas above `@gas_window` (see the top of the module); every other
  # field (memory, refund, return data, contract, ...) is current. Stack and
  # control opcodes run on the registers alone. A state opcode, a halt, or the
  # end of the frame first writes the registers back (`sync/5`), so opcode
  # modules and callers only ever see a complete `MachineState` (#193).
  #
  # The program is the code decoded once per transaction
  # (`EEVM.Interpreter.InstructionTable.decode/3`): `elem(program, pc)` is the
  # instruction at `pc`, with PUSH data already read and PUSH+JUMP(I) pairs
  # fused into one instruction (#208). Each instruction carries its checks,
  # made once before it runs: static gas, then the stack bounds. Fewer items
  # than its minimum depth is a stack underflow; above its maximum depth the
  # opcode would end with more than 1024 items, a stack overflow (Yellow Paper
  # §9.4.2). Opcodes can therefore assume their inputs are there and push
  # freely.

  # Loads the frame's program: from the transaction's cache when this code ran
  # before, else decoded and cached. Traced runs decode a traced program; the
  # tracer is fixed for a transaction, and so is the hardfork's table.
  defp load_program(%MachineState{frame: %{code: code} = frame, substate: substate} = state) do
    {program, cache} =
      case substate.program_cache do
        %{^code => program} = cache ->
          {program, cache}

        cache ->
          program =
            InstructionTable.decode(code, state.env.instruction_table, state.tracer != nil)

          {program, Map.put(cache, code, program)}
      end

    %{state | frame: %{frame | program: program}, substate: %{substate | program_cache: cache}}
  end

  # The instruction's gas and stack checks pass.
  defguardp runnable(cost, min_depth, max_depth, gas, depth)
            when cost <= gas and depth >= min_depth and depth <= max_depth

  # The hot path matches the instruction here rather than in a function head:
  # a call per opcode just to match it made loopMul about 3x slower.
  defp loop(state, program, pc, gas, stack, depth) do
    case elem(program, pc) do
      {op, cost, min_depth, max_depth, arg}
      when runnable(cost, min_depth, max_depth, gas, depth) ->
        step(state, program, pc, gas - cost, stack, depth, op, arg)

      instruction ->
        execute(instruction, state, program, pc, gas, stack, depth)
    end
  end

  # `execute/7` handles everything off the hot path.

  # Running off the end of the code is an implicit STOP: empty output.
  defp execute(:end, state, _program, pc, gas, stack, depth) do
    state
    |> sync(pc, gas, stack, depth)
    |> MachineState.update_frame(&%{&1 | return_data: <<>>})
    |> MachineState.halt(:stopped)
  end

  # Traced programs wrap each instruction: record the step, then run it.
  defp execute({:trace, byte, instruction}, state, program, pc, gas, stack, depth) do
    state = trace_opcode(state, byte, instruction, pc, gas, stack)

    case instruction do
      {op, cost, min_depth, max_depth, arg}
      when runnable(cost, min_depth, max_depth, gas, depth) ->
        step(state, program, pc, gas - cost, stack, depth, op, arg)

      instruction ->
        execute(instruction, state, program, pc, gas, stack, depth)
    end
  end

  # A fused PUSH+JUMP(I) that cannot run whole runs its PUSH alone, then its
  # JUMP(I) from the program, so a failure is reported where it happens.
  defp execute({fused, _cost, _min, _max, arg}, state, program, pc, gas, stack, depth)
       when fused in [:jump_to, :jumpi_to],
       do: execute(elem(arg, 0), state, program, pc, gas, stack, depth)

  defp execute({_op, cost, min_depth, _max, _arg}, state, _program, pc, gas, stack, depth) do
    cond do
      cost > gas -> out_of_gas(state, pc, gas, stack, depth)
      depth < min_depth -> halt(state, :stack_underflow, pc, gas, stack, depth)
      true -> halt(state, :stack_overflow, pc, gas, stack, depth)
    end
  end

  # `step/8` runs an instruction whose gas is already paid: one clause per
  # opcode, most generated from the Registry, so each clause's module, stack
  # effect, and static-call rule are compile-time constants. It takes
  # `loop/6`'s arguments first, in the same order, and the opcode and its
  # `arg` last, so `loop -> step -> loop` moves no registers (12% on loopMul).

  # Stack opcodes are pure functions of the stack list.
  for opcode <- 0..255, {:ok, %{kind: :stack} = info} <- [Registry.info(opcode)] do
    defp step(state, program, pc, gas, stack, depth, unquote(opcode), _arg) do
      stack = unquote(info.module).stack_op(unquote(opcode), stack)
      loop(state, program, pc + 1, gas, stack, depth + unquote(info.outputs - info.inputs))
    end
  end

  # Control opcodes read or move the loop's own registers.

  # PUSH0 (EIP-3855) pushes 0; PUSH1–PUSH32 push the value decoded with the
  # program and skip their data.
  defp step(state, program, pc, gas, stack, depth, 0x5F, _arg),
    do: loop(state, program, pc + 1, gas, [0 | stack], depth + 1)

  defp step(state, program, pc, gas, stack, depth, push, value) when push in 0x60..0x7F,
    do: loop(state, program, pc + push - 0x5E, gas, [value | stack], depth + 1)

  defp step(state, program, pc, gas, [dest | stack], depth, 0x56, _arg),
    do: jump(state, program, pc, gas, stack, depth - 1, dest)

  defp step(state, program, pc, gas, [_dest, 0 | stack], depth, 0x57, _arg),
    do: loop(state, program, pc + 1, gas, stack, depth - 2)

  defp step(state, program, pc, gas, [dest, _condition | stack], depth, 0x57, _arg),
    do: jump(state, program, pc, gas, stack, depth - 2, dest)

  defp step(state, program, pc, gas, stack, depth, 0x58, _arg),
    do: loop(state, program, pc + 1, gas, [pc | stack], depth + 1)

  # GAS pushes the gas left after its own cost.
  defp step(state, program, pc, gas, stack, depth, 0x5A, _arg),
    do: loop(state, program, pc + 1, gas, [state.frame.gas + gas | stack], depth + 1)

  defp step(state, program, pc, gas, stack, depth, 0x5B, _arg),
    do: loop(state, program, pc + 1, gas, stack, depth)

  # Fused PUSH+JUMP and PUSH+JUMPI: the pushed destination never reaches the
  # stack. It is checked like any other, so an invalid one halts at the jump.
  defp step(state, program, pc, gas, stack, depth, :jump_to, {_push, dest}),
    do: jump(state, program, pc, gas, stack, depth, dest)

  defp step(state, program, _pc, gas, [0 | stack], depth, :jumpi_to, {_push, _dest, next_pc}),
    do: loop(state, program, next_pc, gas, stack, depth - 1)

  defp step(state, program, pc, gas, [_ | stack], depth, :jumpi_to, {_push, dest, _next}),
    do: jump(state, program, pc, gas, stack, depth - 1, dest)

  # State opcodes run on the whole machine state; the loop then resumes from
  # the frame they return.
  for opcode <- 0..255, {:ok, %{kind: :state} = info} <- [Registry.info(opcode)] do
    defp step(state, _program, pc, gas, stack, depth, unquote(opcode), _arg) do
      state = sync(state, pc, gas, stack, depth)

      if forbidden_in_static?(state, unquote(Map.get(info, :state_mutating, false))),
        do: state_op_result({:error, :static_state_modification, state}),
        else: state_op_result(unquote(info.module).execute(unquote(opcode), state))
    end
  end

  # Inside a STATICCALL frame, state-mutating opcodes (SSTORE, TSTORE,
  # LOG0..4, CREATE, CREATE2, SELFDESTRUCT) are an exceptional halt (EIP-214).
  defp forbidden_in_static?(%MachineState{frame: frame}, state_mutating?),
    do: state_mutating? and frame.is_static

  # JUMP and JUMPI may only land on a JUMPDEST opcode (Yellow Paper §9.4.3).
  # PUSH data decodes as `:push_data`, so the program itself is the JUMPDEST map.
  defp jump(state, program, pc, gas, stack, depth, dest) do
    case dest < tuple_size(program) and elem(program, dest) do
      {0x5B, _cost, _min, _max, _arg} -> loop(state, program, dest, gas, stack, depth)
      {:trace, 0x5B, _instruction} -> loop(state, program, dest, gas, stack, depth)
      _ -> halt(state, :invalid_jump_destination, pc, gas, stack, depth)
    end
  end

  defp state_op_result({:ok, state}), do: run_loop(state)
  defp state_op_result({:error, :out_of_gas, state}), do: annotate_last_error(state, :out_of_gas)

  defp state_op_result({:error, reason, state}),
    do: state |> MachineState.halt({:error, reason}) |> annotate_last_error(reason)

  # Writes the registers back into the frame.
  defp sync(%MachineState{frame: frame} = state, pc, gas, stack, depth) do
    stack = %Stack{elements: stack, size: depth}
    %{state | frame: %{frame | pc: pc, gas: frame.gas + gas, stack: stack}}
  end

  # The register cannot pay for the opcode: refill it from the gas held back
  # above `@gas_window` and retry, or halt when there is none.
  defp out_of_gas(%MachineState{frame: %{gas: 0}} = state, pc, gas, stack, depth),
    do: halt(state, :out_of_gas, pc, gas, stack, depth)

  defp out_of_gas(state, pc, gas, stack, depth),
    do: state |> sync(pc, gas, stack, depth) |> run_loop()

  # An exceptional halt: `MachineState.halt/2` burns the frame's remaining gas.
  defp halt(state, reason, pc, gas, stack, depth) do
    state
    |> sync(pc, gas, stack, depth)
    |> MachineState.halt(halt_status(reason))
    |> annotate_last_error(reason)
  end

  defp halt_status(:out_of_gas), do: :out_of_gas
  defp halt_status(reason), do: {:error, reason}

  # Only traced programs call this (see `execute/7`). It records the raw code
  # byte, so a byte the fork does not define traces as itself, not as INVALID.
  defp trace_opcode(
         %MachineState{tracer: tracer, frame: frame} = state,
         byte,
         instruction,
         pc,
         gas,
         stack
       ) do
    {_op, cost, _min, _max, _arg} = instruction

    step = %TraceStep{
      pc: pc,
      op: Tracer.op_name(byte),
      op_byte: byte,
      gas_remaining: frame.gas + gas,
      # INVALID consumes all remaining gas.
      gas_cost: if(byte == 0xFE, do: frame.gas + gas, else: cost),
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
