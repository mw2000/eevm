defmodule EEVM.Executor do
  @moduledoc """
  The EVM execution engine — fetches, decodes, and dispatches opcodes.

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
  - `execute_opcode/2` is a private dispatch table. Specific opcodes come first,
    then ranges. Elixir matches clauses top-to-bottom, so narrower patterns
    must precede broader ones.
  - Separation of concerns: the executor only orchestrates; opcode modules own
    their semantics.
  """

  alias EEVM.{HardforkConfig, MachineState}
  alias EEVM.Database
  alias EEVM.Gas.Static
  alias EEVM.Transaction.IntrinsicGas
  alias EEVM.Database
  alias EEVM.Gas.Static

  alias EEVM.Opcodes.{
    Arithmetic,
    Bitwise,
    Comparison,
    ControlFlow,
    Crypto,
    Environment.Data,
    Environment.External,
    Environment.Simple,
    Logging,
    StackMemoryStorage.MemoryOps,
    StackMemoryStorage.StackOps,
    StackMemoryStorage.StorageOps,
    System.Calls,
    System.Creation,
    System.Termination
  }

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

        case MachineState.consume_gas(state, static_cost) do
          {:ok, state_after_gas} ->
            case execute_opcode(opcode, state_after_gas) do
              {:ok, new_state} -> run_loop(new_state)
              {:error, :out_of_gas, halted_state} -> halted_state
              {:error, reason, error_state} -> MachineState.halt(error_state, {:error, reason})
            end

          {:error, :out_of_gas, halted_state} ->
            halted_state
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
      if HardforkConfig.enabled?(state.config.hardfork, :eip_3529), do: 5, else: 2

    effective_refund = min(state.refund, div(gas_used, refund_cap_divisor))

    refunded_gas = state.gas + effective_refund

    calldata_floor_gas =
      IntrinsicGas.calldata_floor_gas_cost(state.tx, state.config.hardfork)

    gas_after_floor =
      if calldata_floor_gas > 0 and state.tx.gas_limit > 0 do
        min(refunded_gas, max(state.tx.gas_limit - calldata_floor_gas, 0))
      else
        refunded_gas
      end

    %{state | gas: gas_after_floor, refund: 0}
  end

  defp cleanup_touched_empty_accounts(%MachineState{status: :stopped} = state) do
    cleaned_db =
      Enum.reduce(state.touched_addresses, state.db, fn address, db_acc ->
        if Database.account_empty?(db_acc, address) do
          Database.delete_account(db_acc, address)
        else
          db_acc
        end
      end)

    %{state | db: cleaned_db}
  end

  defp cleanup_touched_empty_accounts(state), do: state

  # Dispatch table for execute_opcode/2.
  #
  # Routes opcode bytes to the module that implements them. Specific opcodes
  # are listed first; ranges follow. This ordering matters — Elixir matches
  # clauses top-to-bottom, so e.g. 0x50 must appear before the 0x51..0x55
  # range to ensure it is caught by its dedicated StackMemoryStorage clause.
  # The fallback clause treats unknown opcodes as INVALID (halt, no gas refund).

  defp execute_opcode(0x55, %{is_static: true} = state),
    do: {:ok, MachineState.halt(state, :reverted)}

  defp execute_opcode(0x5D, %{is_static: true} = state),
    do: {:ok, MachineState.halt(state, :reverted)}

  defp execute_opcode(op, %{is_static: true} = state) when op in 0xA0..0xA4,
    do: {:ok, MachineState.halt(state, :reverted)}

  defp execute_opcode(op, %{is_static: true} = state) when op in [0xF0, 0xF5],
    do: {:ok, MachineState.halt(state, :reverted)}

  defp execute_opcode(0xFF, %{is_static: true} = state),
    do: {:ok, MachineState.halt(state, :reverted)}

  defp execute_opcode(0x00, state), do: Termination.execute(0x00, state)
  defp execute_opcode(op, state) when op in 0x01..0x0B, do: Arithmetic.execute(op, state)
  defp execute_opcode(op, state) when op in 0x10..0x15, do: Comparison.execute(op, state)
  defp execute_opcode(op, state) when op in 0x16..0x1D, do: Bitwise.execute(op, state)
  defp execute_opcode(0x20, state), do: Crypto.execute(0x20, state)

  defp execute_opcode(op, state) when op in [0x30, 0x32, 0x33, 0x34, 0x36, 0x38, 0x3A, 0x3D],
    do: Simple.execute(op, state)

  defp execute_opcode(op, state) when op in [0x35, 0x37, 0x39, 0x3E], do: Data.execute(op, state)

  defp execute_opcode(op, state) when op in [0x31, 0x3B, 0x3C, 0x3F],
    do: External.execute(op, state)

  defp execute_opcode(op, state)
       when op in [0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x48, 0x49, 0x4A],
       do: Simple.execute(op, state)

  defp execute_opcode(0x47, state), do: External.execute(0x47, state)
  defp execute_opcode(0x50, state), do: StackOps.execute(0x50, state)

  defp execute_opcode(op, state) when op in [0x51, 0x52, 0x53, 0x59, 0x5E],
    do: MemoryOps.execute(op, state)

  defp execute_opcode(op, state) when op in [0x54, 0x55, 0x5C, 0x5D],
    do: StorageOps.execute(op, state)

  defp execute_opcode(0x5A, state), do: Simple.execute(0x5A, state)
  defp execute_opcode(op, state) when op in 0x56..0x5B, do: ControlFlow.execute(op, state)
  defp execute_opcode(0x5F, state), do: ControlFlow.execute(0x5F, state)
  defp execute_opcode(op, state) when op in 0x60..0x9F, do: ControlFlow.execute(op, state)
  defp execute_opcode(op, state) when op in 0xA0..0xA4, do: Logging.execute(op, state)

  defp execute_opcode(op, state) when op in [0xF0, 0xF5],
    do: Creation.execute(op, state)

  defp execute_opcode(op, state) when op in [0xF1, 0xF2, 0xF4, 0xFA],
    do: Calls.execute(op, state)

  defp execute_opcode(op, state) when op in [0xF3, 0xFD, 0xFE, 0xFF],
    do: Termination.execute(op, state)

  defp execute_opcode(_op, state), do: {:ok, MachineState.halt(state, :invalid)}
end
