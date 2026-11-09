defmodule EEVM.Interpreter.Instructions.StackMemoryStorage.StorageOps do
  @moduledoc """
  Persistent and transient storage opcodes: SLOAD, SSTORE, TLOAD, and TSTORE.

  ## Persistent Storage (SLOAD/SSTORE)

  Persistent storage is a key-value mapping (256-bit → 256-bit) that persists across
  transactions. Gas costs depend on the hardfork:

  - **SLOAD** (0x54) — reads a storage slot. Costs 2,100 (cold) or 100 (warm) per
    EIP-2929 from Berlin; a flat static price before (see `EEVM.Gas.Static`).
  - **SSTORE** (0x55) — writes a storage slot. Cost depends on the transition from
    original → current → new value (`EEVM.Gas.Dynamic.sstore_cost/4`), plus
    2,100 for a cold slot from Berlin. From Istanbul it fails out of gas when
    no more than 2,300 gas remains (EIP-2200).

  ## Transient Storage (TLOAD/TSTORE)

  Transient storage (EIP-1153) provides a key-value mapping that is automatically
  cleared at the end of each transaction. Useful for reentrancy locks and temporary state.

  - **TLOAD** (0x5C) — reads from transient storage. Costs 100 gas (warm access).
  - **TSTORE** (0x5D) — writes to transient storage. Costs 100 gas (warm access).
  """

  alias EEVM.Database
  alias EEVM.Gas.{Access, Dynamic}
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.{MachineState, Stack}

  @sstore_sentry_gas 2_300

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x54, state) do
    with {:ok, key, s1} <- Stack.pop(state.frame.stack) do
      contract_address = state.frame.contract.address

      {access_cost, state_after_access} =
        Access.storage_access_cost(
          MachineState.update_frame(state, &%{&1 | stack: s1}),
          contract_address,
          key
        )

      case MachineState.consume_gas(state_after_access, access_cost) do
        {:ok, state_after_gas} ->
          value = Database.storage_load(state_after_gas.db, contract_address, key)

          case Stack.push(state_after_gas.frame.stack, value) do
            {:ok, s2} ->
              {:ok,
               state_after_gas
               |> MachineState.update_frame(&%{&1 | stack: s2})
               |> MachineState.advance_pc()}

            {:error, reason} ->
              {:error, reason, state_after_gas}
          end

        {:error, :out_of_gas, halted} ->
          {:error, :out_of_gas, halted}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x55, state) do
    # EIP-2200 (Istanbul+) sentry: SSTORE fails out of gas unless more than the
    # call stipend remains, so a stipend-funded call can never write storage.
    if HardforkConfig.enabled?(state.env.config.hardfork, :eip_2200) and
         state.frame.gas <= @sstore_sentry_gas do
      {:error, :out_of_gas, MachineState.halt(state, :out_of_gas)}
    else
      sstore(state)
    end
  end

  # TLOAD (EIP-1153, Cancun+): reads from transient storage — a key-value map
  # per account, shared by every frame of the transaction and cleared at its end.
  def execute(0x5C, state) do
    with {:ok, key, s1} <- Stack.pop(state.frame.stack),
         value =
           Map.get(state.substate.transient_storage, {state.frame.contract.address, key}, 0),
         {:ok, s2} <- Stack.push(s1, value) do
      {:ok, state |> MachineState.update_frame(&%{&1 | stack: s2}) |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # TSTORE (EIP-1153, Cancun+): writes to transient storage. The static-context
  # guard in the executor rejects TSTORE before this clause is reached in static mode.
  def execute(0x5D, state) do
    with {:ok, key, s1} <- Stack.pop(state.frame.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      sub = state.substate
      slot = {state.frame.contract.address, key}
      new_sub = %{sub | transient_storage: Map.put(sub.transient_storage, slot, value)}

      state_after =
        state
        |> MachineState.update_frame(&%{&1 | stack: s2})
        |> Map.put(:substate, new_sub)

      {:ok, MachineState.advance_pc(state_after)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}

  defp sstore(state) do
    with {:ok, key, s1} <- Stack.pop(state.frame.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      state_after_stack = MachineState.update_frame(state, &%{&1 | stack: s2})
      contract_address = state_after_stack.frame.contract.address

      {access_cost, state_after_access} =
        Access.sstore_access_cost(state_after_stack, contract_address, key)

      {original_value, state_with_original} = get_original_value(state_after_access, key)
      current_value = Database.storage_load(state_with_original.db, contract_address, key)

      {sstore_gas, refund_delta} =
        Dynamic.sstore_cost(original_value, current_value, value, state.env.config.hardfork)

      total_cost = access_cost + sstore_gas

      case MachineState.consume_gas(state_with_original, total_cost) do
        {:ok, state_after_gas} ->
          state_after_refund = apply_refund_delta(state_after_gas, refund_delta)
          new_db = Database.storage_store(state_after_refund.db, contract_address, key, value)
          {:ok, %{state_after_refund | db: new_db} |> MachineState.advance_pc()}

        {:error, :out_of_gas, halted} ->
          {:error, :out_of_gas, halted}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp get_original_value(state, key) do
    address = state.frame.contract.address

    case Map.fetch(state.substate.original_storage, {address, key}) do
      {:ok, value} ->
        {value, state}

      :error ->
        value = Database.storage_load(state.db, address, key)
        sub = state.substate
        new_sub = %{sub | original_storage: Map.put(sub.original_storage, {address, key}, value)}
        {value, %{state | substate: new_sub}}
    end
  end

  defp apply_refund_delta(state, refund_delta) when refund_delta > 0,
    do: MachineState.add_refund(state, refund_delta)

  defp apply_refund_delta(state, refund_delta) when refund_delta < 0,
    do: MachineState.sub_refund(state, abs(refund_delta))

  defp apply_refund_delta(state, 0), do: state
end
