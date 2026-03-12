defmodule EEVM.Opcodes.StackMemoryStorage.StorageOps do
  @moduledoc false

  alias EEVM.{MachineState, Stack, Storage}

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x54, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack),
         value = Storage.load(state.storage, key),
         {:ok, s2} <- Stack.push(s1, value) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
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

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
