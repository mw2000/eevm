defmodule EEVM.Opcodes.System.Termination do
  @moduledoc """
  Execution-terminating opcodes: STOP, RETURN, REVERT, INVALID, and SELFDESTRUCT.

  These opcodes end the current execution frame. STOP and RETURN indicate success,
  REVERT indicates a controlled failure (state changes are rolled back but gas for
  the return data copy is still consumed), and INVALID halts with an error.

  SELFDESTRUCT (0xFF) transfers the contract's balance to a beneficiary address
  and marks the contract for deletion. Per EIP-6780, in post-Cancun transactions
  SELFDESTRUCT only has its full effect when called in the same transaction that
  created the contract.
  """

  alias EEVM.{MachineState, Memory, Stack, WorldState}
  alias EEVM.Gas.Memory, as: GasMemory

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x00, state), do: {:ok, MachineState.halt(state, :stopped)}

  def execute(0xF3, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, length, s2} <- Stack.pop(s1),
         expansion_cost =
           GasMemory.memory_expansion_cost(Memory.size(state.memory), offset, length),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s2}, expansion_cost) do
      {return_data, new_memory} = Memory.read_bytes(state_after_gas.memory, offset, length)

      {:ok,
       %{state_after_gas | stack: s2, memory: new_memory, return_data: return_data}
       |> MachineState.halt(:stopped)}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  def execute(0xFD, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, length, s2} <- Stack.pop(s1),
         expansion_cost =
           GasMemory.memory_expansion_cost(Memory.size(state.memory), offset, length),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s2}, expansion_cost) do
      {return_data, new_memory} = Memory.read_bytes(state_after_gas.memory, offset, length)

      {:ok,
       %{state_after_gas | stack: s2, memory: new_memory, return_data: return_data}
       |> MachineState.halt(:reverted)}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  def execute(0xFF, state) do
    with {:ok, beneficiary, s1} <- Stack.pop(state.stack) do
      contract_address = state.contract.address
      balance = WorldState.get_balance(state.world_state, contract_address)

      beneficiary_exists = WorldState.account_exists?(state.world_state, beneficiary)
      dynamic_cost = if not beneficiary_exists and balance > 0, do: 25_000, else: 0

      case MachineState.consume_gas(%{state | stack: s1}, dynamic_cost) do
        {:ok, state_after_gas} ->
          # EIP-6780: post-Cancun, SELFDESTRUCT only fully deletes the account
          # when the contract was created in the same transaction. Otherwise it
          # only transfers the balance to the beneficiary.
          created_this_tx =
            MapSet.member?(state_after_gas.created_addresses, contract_address)

          world_state_after =
            if created_this_tx do
              # EIP-6780: full deletion for contracts created in the same tx
              ws = WorldState.delete_account(state_after_gas.world_state, contract_address)

              if beneficiary != contract_address do
                WorldState.set_balance(
                  ws,
                  beneficiary,
                  WorldState.get_balance(ws, beneficiary) + balance
                )
              else
                ws
              end
            else
              if beneficiary == contract_address do
                state_after_gas.world_state
              else
                beneficiary_balance =
                  WorldState.get_balance(state_after_gas.world_state, beneficiary)

                state_after_gas.world_state
                |> WorldState.set_balance(contract_address, 0)
                |> WorldState.set_balance(beneficiary, beneficiary_balance + balance)
              end
            end

          {:ok, MachineState.halt(%{state_after_gas | world_state: world_state_after}, :stopped)}

        {:error, :out_of_gas, halted_state} ->
          {:error, :out_of_gas, halted_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0xFE, state), do: {:ok, MachineState.halt(state, :invalid)}
  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
