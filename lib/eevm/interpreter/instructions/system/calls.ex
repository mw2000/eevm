defmodule EEVM.Interpreter.Instructions.System.Calls do
  @moduledoc """
  Cross-contract call opcodes.

  This module handles the most complex EVM operations — those that spawn nested
  execution frames and interact with the world state.

  ## Cross-Contract Calls

  - **CALL** (0xF1) — calls another contract with optional value transfer.
  - **CALLCODE** (0xF2) — like CALL but executes the target's code in the
    caller's storage context (legacy, superseded by DELEGATECALL).
  - **DELEGATECALL** (0xF4) — executes the target's code in the caller's
    context, preserving `msg.sender` and `msg.value` (EIP-7).
  - **STATICCALL** (0xFA) — read-only call that reverts on state changes (EIP-214).

  All call opcodes use EIP-150 gas forwarding: `min(requested, available - available/64)`.

  ## Target access and EIP-7702 delegation

  Each call charges EIP-2929 cold access for its target on top of the warm
  cost in the static table. From Prague, a target whose code is a delegation
  designator (`0xef0100 || delegate`) runs the delegate's code, charges the
  delegate's cold or warm access as well, and never dispatches to a
  precompile, even when the delegate is one.
  """

  alias EEVM.Context.Contract
  alias EEVM.{Database, Delegation, HardforkConfig}
  alias EEVM.Gas.Access
  alias EEVM.Gas.Dynamic
  alias EEVM.Gas.Memory, as: GasMemory
  alias EEVM.Interpreter
  alias EEVM.Interpreter.{Journal, MachineState, Memory, Stack}
  alias EEVM.Precompiles

  # Warm access is already charged as the static cost of every call opcode.
  @warm_access_cost 100
  @max_call_depth 1024

  @doc "Execute CALL (0xF1), CALLCODE (0xF2), DELEGATECALL (0xF4), or STATICCALL (0xFA)."
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0xF1, state) do
    with {:ok, gas_requested, s1} <- Stack.pop(state.frame.stack),
         {:ok, address, s2} <- Stack.pop(s1),
         {:ok, value, s3} <- Stack.pop(s2),
         {:ok, args_offset, s4} <- Stack.pop(s3),
         {:ok, args_size, s5} <- Stack.pop(s4),
         {:ok, ret_offset, s6} <- Stack.pop(s5),
         {:ok, ret_size, s7} <- Stack.pop(s6) do
      # EIP-214: a value-bearing CALL inside a static frame is an exceptional halt.
      if state.frame.is_static and value > 0 do
        {:error, :static_state_modification, state}
      else
        execute_call(
          state,
          s7,
          gas_requested,
          address,
          value,
          args_offset,
          args_size,
          ret_offset,
          ret_size,
          state.frame.is_static
        )
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0xF2, state) do
    with {:ok, gas_requested, s1} <- Stack.pop(state.frame.stack),
         {:ok, address, s2} <- Stack.pop(s1),
         {:ok, value, s3} <- Stack.pop(s2),
         {:ok, args_offset, s4} <- Stack.pop(s3),
         {:ok, args_size, s5} <- Stack.pop(s4),
         {:ok, ret_offset, s6} <- Stack.pop(s5),
         {:ok, ret_size, s7} <- Stack.pop(s6) do
      # EIP-214 restricts only CALL: CALLCODE "sends" value to the caller itself,
      # so it is allowed with value inside a static frame.
      execute_delegatecall(
        state,
        s7,
        gas_requested,
        address,
        value,
        args_offset,
        args_size,
        ret_offset,
        ret_size,
        state.frame.contract.address,
        true,
        true
      )
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0xF4, state) do
    with {:ok, gas_requested, s1} <- Stack.pop(state.frame.stack),
         {:ok, address, s2} <- Stack.pop(s1),
         {:ok, args_offset, s3} <- Stack.pop(s2),
         {:ok, args_size, s4} <- Stack.pop(s3),
         {:ok, ret_offset, s5} <- Stack.pop(s4),
         {:ok, ret_size, s6} <- Stack.pop(s5) do
      execute_delegatecall(
        state,
        s6,
        gas_requested,
        address,
        state.frame.contract.callvalue,
        args_offset,
        args_size,
        ret_offset,
        ret_size,
        state.frame.contract.caller,
        false,
        false
      )
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0xFA, state) do
    with {:ok, gas_requested, s1} <- Stack.pop(state.frame.stack),
         {:ok, address, s2} <- Stack.pop(s1),
         {:ok, args_offset, s3} <- Stack.pop(s2),
         {:ok, args_size, s4} <- Stack.pop(s3),
         {:ok, ret_offset, s5} <- Stack.pop(s4),
         {:ok, ret_size, s6} <- Stack.pop(s5) do
      execute_call(
        state,
        s6,
        gas_requested,
        address,
        0,
        args_offset,
        args_size,
        ret_offset,
        ret_size,
        true
      )
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}

  defp execute_call(
         state,
         stack,
         gas_requested,
         address,
         value,
         args_offset,
         args_size,
         ret_offset,
         ret_size,
         child_static?
       ) do
    {access_cost, state, target_code, delegated?} = access_target(state, address)
    depth = state.frame.depth
    account_exists = Database.account_exists?(state.db, address)

    call_cost =
      access_cost +
        Dynamic.call_value_cost(value) +
        Dynamic.call_new_account_cost(account_exists, value) +
        call_memory_expansion_cost(
          state.frame.memory,
          args_offset,
          args_size,
          ret_offset,
          ret_size
        )

    with {:ok, state_after_cost} <-
           MachineState.consume_gas(
             MachineState.update_frame(state, &%{&1 | stack: stack}),
             call_cost
           ),
         {:ok, db_after_transfer} <-
           Database.transfer(
             state_after_cost.db,
             state_after_cost.frame.contract.address,
             address,
             value
           ) do
      {calldata, memory_after_read} =
        Memory.read_bytes(state_after_cost.frame.memory, args_offset, args_size)

      forwarded_gas = Dynamic.call_forwarded_gas(state_after_cost.frame.gas, gas_requested)

      case MachineState.consume_gas(
             MachineState.update_frame(state_after_cost, &%{&1 | memory: memory_after_read}),
             forwarded_gas
           ) do
        # The depth limit is checked only after access, memory, and value costs
        # are charged; the forwarded gas comes back unused.
        {:ok, _state_after_forward} when depth >= @max_call_depth ->
          call_failed(
            MachineState.update_frame(state_after_cost, &%{&1 | memory: memory_after_read}),
            stack
          )

        {:ok, state_after_forward} ->
          if not delegated? and Precompiles.precompile?(address, state_after_forward.env.config) and
               target_code == <<>> do
            child_gas = forwarded_gas + Dynamic.call_stipend(value)

            case Precompiles.execute(address, calldata, child_gas, state_after_forward.env.config) do
              {:ok, output, gas_used} ->
                remaining_gas = child_gas - gas_used
                memory_result = write_return_data(memory_after_read, ret_offset, ret_size, output)
                {:ok, stack_after_call} = Stack.push(state_after_forward.frame.stack, 1)
                # The call succeeded, so its value transfer stands.
                state_after_touch =
                  MachineState.touch_address(
                    %{state_after_forward | db: db_after_transfer},
                    address
                  )

                {:ok,
                 state_after_touch
                 |> MachineState.update_frame(
                   &%{
                     &1
                     | stack: stack_after_call,
                       memory: memory_result,
                       return_data: output,
                       gas: &1.gas + remaining_gas
                   }
                 )
                 |> MachineState.advance_pc()}

              {:error, _reason} ->
                memory_result = write_return_data(memory_after_read, ret_offset, ret_size, <<>>)
                {:ok, stack_after_call} = Stack.push(state_after_forward.frame.stack, 0)

                {:ok,
                 state_after_forward
                 |> MachineState.update_frame(
                   &%{
                     &1
                     | stack: stack_after_call,
                       memory: memory_result,
                       return_data: <<>>
                   }
                 )
                 |> MachineState.advance_pc()}
            end
          else
            state_after_touch = MachineState.touch_address(state_after_forward, address)

            child_contract =
              Contract.new(
                address: address,
                caller: state_after_forward.frame.contract.address,
                callvalue: value,
                calldata: calldata,
                balances: state_after_forward.frame.contract.balances
              )

            child_gas = forwarded_gas + Dynamic.call_stipend(value)

            child_state =
              MachineState.new(target_code,
                gas: child_gas,
                db: db_after_transfer,
                tx: state_after_touch.env.tx,
                block: state_after_touch.env.block,
                contract: child_contract,
                config: state_after_touch.env.config,
                touched_addresses: state_after_touch.substate.touched_addresses,
                accessed_addresses: state_after_touch.substate.accessed_addresses,
                accessed_storage_keys: state_after_touch.substate.accessed_storage_keys,
                created_addresses: state_after_touch.substate.created_addresses,
                transient_storage: state_after_touch.substate.transient_storage,
                selfdestructed_addresses: state_after_touch.substate.selfdestructed_addresses,
                original_storage: state_after_touch.substate.original_storage,
                is_static: child_static?,
                depth: state_after_touch.frame.depth + 1,
                tracer: state_after_touch.tracer
              )

            child_result = Interpreter.run_loop(child_state)
            merged = Journal.merge_child_result(state_after_forward, child_result)

            memory_result =
              write_return_data(
                memory_after_read,
                ret_offset,
                ret_size,
                child_result.frame.return_data
              )

            result_flag = if child_result.status == :stopped, do: 1, else: 0
            {:ok, stack_after_call} = Stack.push(state_after_forward.frame.stack, result_flag)

            {:ok,
             merged
             |> MachineState.update_frame(
               &%{
                 &1
                 | stack: stack_after_call,
                   memory: memory_result,
                   return_data: child_result.frame.return_data,
                   gas: state_after_forward.frame.gas + returned_gas(child_result)
               }
             )
             |> MachineState.advance_pc()}
          end

        {:error, :out_of_gas, _halted_state} ->
          call_failed(state_after_cost, stack)
      end
    else
      {:error, :insufficient_balance} ->
        call_failed(
          MachineState.update_frame(state, &%{&1 | stack: stack, gas: &1.gas - call_cost}),
          stack
        )

      {:error, :out_of_gas, halted_state} ->
        {:error, :out_of_gas, halted_state}
    end
  end

  defp execute_delegatecall(
         state,
         stack,
         gas_requested,
         address,
         callvalue,
         args_offset,
         args_size,
         ret_offset,
         ret_size,
         caller,
         charge_value_cost?,
         add_stipend?
       ) do
    {access_cost, state, target_code, delegated?} = access_target(state, address)
    depth = state.frame.depth

    call_cost =
      access_cost +
        if(charge_value_cost?, do: Dynamic.call_value_cost(callvalue), else: 0) +
        call_memory_expansion_cost(
          state.frame.memory,
          args_offset,
          args_size,
          ret_offset,
          ret_size
        )

    with {:ok, state_after_cost} <-
           MachineState.consume_gas(
             MachineState.update_frame(state, &%{&1 | stack: stack}),
             call_cost
           ) do
      {calldata, memory_after_read} =
        Memory.read_bytes(state_after_cost.frame.memory, args_offset, args_size)

      forwarded_gas = Dynamic.call_forwarded_gas(state_after_cost.frame.gas, gas_requested)

      case MachineState.consume_gas(
             MachineState.update_frame(state_after_cost, &%{&1 | memory: memory_after_read}),
             forwarded_gas
           ) do
        # The depth limit is checked only after access, memory, and value costs
        # are charged; the forwarded gas comes back unused.
        {:ok, _state_after_forward} when depth >= @max_call_depth ->
          call_failed(
            MachineState.update_frame(state_after_cost, &%{&1 | memory: memory_after_read}),
            stack
          )

        {:ok, state_after_forward} ->
          child_gas =
            forwarded_gas + if(add_stipend?, do: Dynamic.call_stipend(callvalue), else: 0)

          if not delegated? and Precompiles.precompile?(address, state_after_forward.env.config) and
               target_code == <<>> do
            case Precompiles.execute(address, calldata, child_gas, state_after_forward.env.config) do
              {:ok, output, gas_used} ->
                remaining_gas = child_gas - gas_used
                memory_result = write_return_data(memory_after_read, ret_offset, ret_size, output)
                {:ok, stack_after_call} = Stack.push(state_after_forward.frame.stack, 1)
                state_after_touch = MachineState.touch_address(state_after_forward, address)

                {:ok,
                 state_after_touch
                 |> MachineState.update_frame(
                   &%{
                     &1
                     | stack: stack_after_call,
                       memory: memory_result,
                       return_data: output,
                       gas: &1.gas + remaining_gas
                   }
                 )
                 |> MachineState.advance_pc()}

              {:error, _reason} ->
                memory_result = write_return_data(memory_after_read, ret_offset, ret_size, <<>>)
                {:ok, stack_after_call} = Stack.push(state_after_forward.frame.stack, 0)

                {:ok,
                 state_after_forward
                 |> MachineState.update_frame(
                   &%{
                     &1
                     | stack: stack_after_call,
                       memory: memory_result,
                       return_data: <<>>
                   }
                 )
                 |> MachineState.advance_pc()}
            end
          else
            state_after_touch = MachineState.touch_address(state_after_forward, address)

            child_contract =
              Contract.new(
                address: state_after_forward.frame.contract.address,
                caller: caller,
                callvalue: callvalue,
                calldata: calldata,
                balances: state_after_forward.frame.contract.balances
              )

            child_state =
              MachineState.new(target_code,
                gas: child_gas,
                db: state_after_touch.db,
                tx: state_after_touch.env.tx,
                block: state_after_touch.env.block,
                contract: child_contract,
                config: state_after_touch.env.config,
                touched_addresses: state_after_touch.substate.touched_addresses,
                accessed_addresses: state_after_touch.substate.accessed_addresses,
                accessed_storage_keys: state_after_touch.substate.accessed_storage_keys,
                created_addresses: state_after_touch.substate.created_addresses,
                transient_storage: state_after_touch.substate.transient_storage,
                selfdestructed_addresses: state_after_touch.substate.selfdestructed_addresses,
                original_storage: state_after_touch.substate.original_storage,
                is_static: state_after_touch.frame.is_static,
                depth: state_after_touch.frame.depth + 1,
                tracer: state_after_touch.tracer
              )

            child_result = Interpreter.run_loop(child_state)
            merged = Journal.merge_child_result(state_after_forward, child_result)

            memory_result =
              write_return_data(
                memory_after_read,
                ret_offset,
                ret_size,
                child_result.frame.return_data
              )

            result_flag = if child_result.status == :stopped, do: 1, else: 0
            {:ok, stack_after_call} = Stack.push(state_after_forward.frame.stack, result_flag)

            {:ok,
             merged
             |> MachineState.update_frame(
               &%{
                 &1
                 | stack: stack_after_call,
                   memory: memory_result,
                   return_data: child_result.frame.return_data,
                   gas: state_after_forward.frame.gas + returned_gas(child_result)
               }
             )
             |> MachineState.advance_pc()}
          end

        {:error, :out_of_gas, _halted_state} ->
          call_failed(state_after_cost, stack)
      end
    else
      {:error, :out_of_gas, halted_state} ->
        {:error, :out_of_gas, halted_state}
    end
  end

  # Only STOP/RETURN and REVERT hand unused gas back to the caller; an exceptional
  # halt consumes everything forwarded to the child.
  defp returned_gas(%MachineState{status: status, frame: frame})
       when status in [:stopped, :reverted],
       do: frame.gas

  defp returned_gas(_child_result), do: 0

  # Returns the access cost beyond the static warm cost, the state with the
  # target (and delegate) warmed, the code to run, and whether the target
  # delegates.
  defp access_target(state, address) do
    {target_cost, state} = Access.address_access_cost(state, address)
    code = Database.get_code(state.db, address)

    with true <- HardforkConfig.enabled?(state.env.config.hardfork, :eip_7702),
         {:ok, delegate} <- Delegation.delegated_address(code) do
      {delegate_cost, state} = Access.address_access_cost(state, delegate)

      {target_cost - @warm_access_cost + delegate_cost, state,
       Database.get_code(state.db, delegate), true}
    else
      _ -> {target_cost - @warm_access_cost, state, code, false}
    end
  end

  defp call_memory_expansion_cost(memory, args_offset, args_size, ret_offset, ret_size) do
    current_size = Memory.size(memory)

    args_end = args_offset + args_size
    ret_end = ret_offset + ret_size
    needed = max(args_end, ret_end)

    if needed == 0 do
      0
    else
      GasMemory.memory_expansion_cost(current_size, 0, needed)
    end
  end

  defp write_return_data(memory, _offset, 0, _return_data), do: memory

  defp write_return_data(memory, offset, size, return_data) do
    bytes =
      for i <- 0..(size - 1), into: <<>> do
        if i < byte_size(return_data), do: <<:binary.at(return_data, i)>>, else: <<0>>
      end

    bytes
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.reduce(memory, fn {byte, i}, mem ->
      Memory.store_byte(mem, offset + i, byte)
    end)
  end

  # A call that fails before running (depth limit, insufficient balance)
  # empties the return data buffer, as geth's `interpreter.returnData = ret` does.
  defp call_failed(state, stack) do
    {:ok, stack_after_call} = Stack.push(stack, 0)

    {:ok,
     state
     |> MachineState.update_frame(&%{&1 | stack: stack_after_call, return_data: <<>>})
     |> MachineState.advance_pc()}
  end
end
