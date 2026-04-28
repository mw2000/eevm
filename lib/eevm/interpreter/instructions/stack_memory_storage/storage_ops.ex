defmodule EEVM.Interpreter.Instructions.StackMemoryStorage.StorageOps do
  @moduledoc """
  Persistent and transient storage opcodes: SLOAD, SSTORE, TLOAD, and TSTORE.

  ## Persistent Storage (SLOAD/SSTORE)

  Persistent storage is a key-value mapping (256-bit → 256-bit) that persists across
  transactions. Gas costs follow the EIP-2200 structured schedule with EIP-2929
  cold/warm access tracking:

  - **SLOAD** (0x54) — reads a storage slot. Costs 2,100 (cold) or 100 (warm) per EIP-2929.
  - **SSTORE** (0x55) — writes a storage slot. Cost depends on the transition from
    original → current → new value, with refunds for clearing slots (EIP-3529).

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

  @cold_sload_cost 2100

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x54, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack) do
      contract_address = state.contract.address

      {access_cost, state_after_access} =
        Access.storage_access_cost(%{state | stack: s1}, contract_address, key)

      case MachineState.consume_gas(state_after_access, access_cost) do
        {:ok, state_after_gas} ->
          value = Database.storage_load(state_after_gas.db, contract_address, key)

          case Stack.push(state_after_gas.stack, value) do
            {:ok, s2} -> {:ok, %{state_after_gas | stack: s2} |> MachineState.advance_pc()}
            {:error, reason} -> {:error, reason, state_after_gas}
          end

        {:error, :out_of_gas, halted} ->
          {:error, :out_of_gas, halted}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x55, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      state_after_stack = %{state | stack: s2}
      contract_address = state_after_stack.contract.address
      access_key = {contract_address, key}
      is_warm = MapSet.member?(state_after_stack.accessed_storage_keys, access_key)

      state_after_access =
        if is_warm do
          state_after_stack
        else
          %{
            state_after_stack
            | accessed_storage_keys:
                MapSet.put(state_after_stack.accessed_storage_keys, access_key)
          }
        end

      cold_cost = if is_warm, do: 0, else: @cold_sload_cost
      {original_value, state_with_original} = get_original_value(state_after_access, key)
      current_value = Database.storage_load(state_with_original.db, contract_address, key)

      {sstore_gas, refund_delta} = Dynamic.sstore_cost(original_value, current_value, value)
      total_cost = cold_cost + sstore_gas

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

  # TLOAD (EIP-1153, Cancun+): reads from transient storage — a key-value map
  # cleared at the end of each transaction. Pre-Cancun, 0x5C is undefined → :invalid.
  def execute(0x5C, %{config: %{hardfork: hardfork}} = state) do
    if HardforkConfig.enabled?(hardfork, :eip_1153) do
      with {:ok, key, s1} <- Stack.pop(state.stack),
           value = Map.get(state.transient_storage, key, 0),
           {:ok, s2} <- Stack.push(s1, value) do
        {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
      else
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:ok, MachineState.halt(state, :invalid)}
    end
  end

  # TSTORE (EIP-1153, Cancun+): writes to transient storage. The static-context
  # guard in the executor rejects TSTORE before this clause is reached in static mode.
  # Pre-Cancun, 0x5D is undefined → :invalid.
  def execute(0x5D, %{config: %{hardfork: hardfork}} = state) do
    if HardforkConfig.enabled?(hardfork, :eip_1153) do
      with {:ok, key, s1} <- Stack.pop(state.stack),
           {:ok, value, s2} <- Stack.pop(s1) do
        new_transient = Map.put(state.transient_storage, key, value)
        {:ok, %{state | stack: s2, transient_storage: new_transient} |> MachineState.advance_pc()}
      else
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:ok, MachineState.halt(state, :invalid)}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}

  defp get_original_value(state, key) do
    case Map.fetch(state.original_storage, key) do
      {:ok, value} ->
        {value, state}

      :error ->
        value = Database.storage_load(state.db, state.contract.address, key)
        {value, %{state | original_storage: Map.put(state.original_storage, key, value)}}
    end
  end

  defp apply_refund_delta(state, refund_delta) when refund_delta > 0,
    do: MachineState.add_refund(state, refund_delta)

  defp apply_refund_delta(state, refund_delta) when refund_delta < 0,
    do: MachineState.sub_refund(state, abs(refund_delta))

  defp apply_refund_delta(state, 0), do: state
end
