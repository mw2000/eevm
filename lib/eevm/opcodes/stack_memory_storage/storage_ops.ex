defmodule EEVM.Opcodes.StackMemoryStorage.StorageOps do
  @moduledoc false

  alias EEVM.{MachineState, Stack, Storage}
  alias EEVM.Gas.Access

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x54, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack) do
      contract_address = state.contract.address

      {access_cost, state_after_access} =
        Access.storage_access_cost(%{state | stack: s1}, contract_address, key)

      case MachineState.consume_gas(state_after_access, access_cost) do
        {:ok, state_after_gas} ->
          value = Storage.load(state_after_gas.storage, key)

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
      new_storage = Storage.store(state.storage, key, value)
      {:ok, %{state | stack: s2, storage: new_storage} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x5C, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack),
         value = Map.get(state.transient_storage, key, 0),
         {:ok, s2} <- Stack.push(s1, value) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x5D, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      new_transient = Map.put(state.transient_storage, key, value)
      {:ok, %{state | stack: s2, transient_storage: new_transient} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
