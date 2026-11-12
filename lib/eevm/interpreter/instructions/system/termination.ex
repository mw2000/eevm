defmodule EEVM.Interpreter.Instructions.System.Termination do
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

  alias EEVM.Database
  alias EEVM.Gas.{Access, Dynamic}
  alias EEVM.Gas.Memory, as: GasMemory
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.Instructions.Helpers
  alias EEVM.Interpreter.{MachineState, Memory, Stack}
  require EEVM.HardforkConfig

  @cold_account_access_cost 2_600

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x00, state), do: {:ok, state |> clear_output() |> MachineState.halt(:stopped)}

  def execute(0xF3, state) do
    with {:ok, offset, s1} <- Stack.pop(state.frame.stack),
         {:ok, length, s2} <- Stack.pop(s1),
         expansion_cost =
           GasMemory.memory_expansion_cost(Memory.size(state.frame.memory), offset, length),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(
             MachineState.update_frame(state, &%{&1 | stack: s2}),
             expansion_cost
           ) do
      {return_data, new_memory} = Memory.read_bytes(state_after_gas.frame.memory, offset, length)

      {:ok,
       state_after_gas
       |> MachineState.update_frame(
         &%{&1 | stack: s2, memory: new_memory, return_data: return_data}
       )
       |> MachineState.halt(:stopped)}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  def execute(0xFD, state) do
    with {:ok, offset, s1} <- Stack.pop(state.frame.stack),
         {:ok, length, s2} <- Stack.pop(s1),
         expansion_cost =
           GasMemory.memory_expansion_cost(Memory.size(state.frame.memory), offset, length),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(
             MachineState.update_frame(state, &%{&1 | stack: s2}),
             expansion_cost
           ) do
      {return_data, new_memory} = Memory.read_bytes(state_after_gas.frame.memory, offset, length)

      {:ok,
       state_after_gas
       |> MachineState.update_frame(
         &%{&1 | stack: s2, memory: new_memory, return_data: return_data}
       )
       |> MachineState.halt(:reverted)}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  def execute(0xFF, state) do
    with {:ok, beneficiary, s1} <- Helpers.pop_address(state.frame.stack) do
      contract_address = state.frame.contract.address
      balance = Database.get_balance(state.db, contract_address)

      {access_cost, state} = beneficiary_access_cost(state, beneficiary)

      dynamic_cost =
        access_cost +
          Dynamic.selfdestruct_new_account_cost(
            Database.account_exists?(state.db, beneficiary),
            Database.account_empty?(state.db, beneficiary),
            balance,
            state.env.config.hardfork
          )

      case MachineState.consume_gas(
             MachineState.update_frame(state, &%{&1 | stack: s1}),
             dynamic_cost
           ) do
        {:ok, state_after_gas} ->
          state_after_touch = MachineState.touch_address(state_after_gas, beneficiary)

          # EIP-6780 (Cancun+): SELFDESTRUCT only fully deletes the account when
          # the contract was created in the same transaction. Pre-Cancun, every
          # SELFDESTRUCT deletes the account. Either way the balance moves now.
          eip_6780_active? =
            HardforkConfig.enabled?(state_after_touch.env.config.hardfork, :eip_6780)

          created_this_tx =
            MapSet.member?(state_after_touch.substate.created_addresses, contract_address)

          full_delete? = not eip_6780_active? or created_this_tx

          db = state_after_touch.db

          db_after =
            cond do
              beneficiary != contract_address ->
                db
                |> Database.set_balance(contract_address, 0)
                |> Database.set_balance(
                  beneficiary,
                  Database.get_balance(db, beneficiary) + balance
                )

              # Being its own beneficiary burns the balance of a deleted account.
              full_delete? ->
                Database.set_balance(db, contract_address, 0)

              true ->
                db
            end

          # The account itself (code, nonce, storage) stays until the transaction
          # ends, when `EEVM.Interpreter.finalize/3` deletes every address in
          # `selfdestructed_addresses`. The set is journaled with the substate, so
          # a reverted frame's SELFDESTRUCT doesn't count.
          substate = state_after_touch.substate

          substate_after =
            if full_delete?,
              do: %{
                substate
                | selfdestructed_addresses:
                    MapSet.put(substate.selfdestructed_addresses, contract_address)
              },
              else: substate

          # Before London each account refunds once per transaction (geth
          # `HasSelfDestructed`).
          refund =
            Dynamic.selfdestruct_refund(
              MapSet.member?(substate.selfdestructed_addresses, contract_address),
              state.env.config.hardfork
            )

          {:ok,
           %{state_after_touch | db: db_after, substate: substate_after}
           |> MachineState.add_refund(refund)
           |> clear_output()
           |> MachineState.halt(:stopped)}

        {:error, :out_of_gas, halted_state} ->
          {:error, :out_of_gas, halted_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0xFE, state), do: {:ok, MachineState.halt(state, :invalid)}

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}

  # EIP-2929: a cold beneficiary costs COLD_ACCOUNT_ACCESS_COST (2,600) on top
  # of the 5,000 static cost and becomes warm; a warm one costs nothing extra.
  defp beneficiary_access_cost(state, beneficiary) do
    if HardforkConfig.enabled?(state.env.config.hardfork, :eip_2929) and
         not Access.warm_address?(state, beneficiary) do
      {@cold_account_access_cost, Access.mark_address_warm(state, beneficiary)}
    else
      {0, state}
    end
  end

  # STOP and SELFDESTRUCT end the frame with empty output. `frame.return_data`
  # still holds the last sub-call's output, which must not become this frame's
  # (CREATE would deploy it as code; the caller would see it as RETURNDATA).
  defp clear_output(state), do: MachineState.update_frame(state, &%{&1 | return_data: <<>>})
end
