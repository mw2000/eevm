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
  """

  alias EEVM.Context.Contract
  alias EEVM.Database
  alias EEVM.Gas.Dynamic
  alias EEVM.Gas.Memory, as: GasMemory
  alias EEVM.Interpreter
  alias EEVM.Interpreter.{Journal, MachineState, Memory, Stack}
  alias EEVM.Precompiles

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0xF1, state) do
    with {:ok, gas_requested, s1} <- Stack.pop(state.stack),
         {:ok, address, s2} <- Stack.pop(s1),
         {:ok, value, s3} <- Stack.pop(s2),
         {:ok, args_offset, s4} <- Stack.pop(s3),
         {:ok, args_size, s5} <- Stack.pop(s4),
         {:ok, ret_offset, s6} <- Stack.pop(s5),
         {:ok, ret_size, s7} <- Stack.pop(s6) do
      cond do
        state.depth >= 1024 ->
          call_failed(state, s7)

        state.is_static and value > 0 ->
          call_failed(state, s7)

        true ->
          execute_call(
            state,
            s7,
            gas_requested,
            address,
            value,
            args_offset,
            args_size,
            ret_offset,
            ret_size
          )
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0xF2, state) do
    with {:ok, gas_requested, s1} <- Stack.pop(state.stack),
         {:ok, address, s2} <- Stack.pop(s1),
         {:ok, value, s3} <- Stack.pop(s2),
         {:ok, args_offset, s4} <- Stack.pop(s3),
         {:ok, args_size, s5} <- Stack.pop(s4),
         {:ok, ret_offset, s6} <- Stack.pop(s5),
         {:ok, ret_size, s7} <- Stack.pop(s6) do
      cond do
        state.depth >= 1024 ->
          call_failed(state, s7)

        state.is_static and value > 0 ->
          call_failed(state, s7)

        true ->
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
            state.contract.address,
            true,
            true
          )
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0xF4, state) do
    with {:ok, gas_requested, s1} <- Stack.pop(state.stack),
         {:ok, address, s2} <- Stack.pop(s1),
         {:ok, args_offset, s3} <- Stack.pop(s2),
         {:ok, args_size, s4} <- Stack.pop(s3),
         {:ok, ret_offset, s5} <- Stack.pop(s4),
         {:ok, ret_size, s6} <- Stack.pop(s5) do
      if state.depth >= 1024 do
        call_failed(state, s6)
      else
        execute_delegatecall(
          state,
          s6,
          gas_requested,
          address,
          state.contract.callvalue,
          args_offset,
          args_size,
          ret_offset,
          ret_size,
          state.contract.caller,
          false,
          false
        )
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0xFA, state) do
    with {:ok, gas_requested, s1} <- Stack.pop(state.stack),
         {:ok, address, s2} <- Stack.pop(s1),
         {:ok, args_offset, s3} <- Stack.pop(s2),
         {:ok, args_size, s4} <- Stack.pop(s3),
         {:ok, ret_offset, s5} <- Stack.pop(s4),
         {:ok, ret_size, s6} <- Stack.pop(s5) do
      if state.depth >= 1024 do
        call_failed(state, s6)
      else
        execute_call(
          %{state | is_static: true},
          s6,
          gas_requested,
          address,
          0,
          args_offset,
          args_size,
          ret_offset,
          ret_size
        )
      end
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
         ret_size
       ) do
    db = state.db
    account_exists = Database.account_exists?(db, address)

    call_cost =
      Dynamic.call_value_cost(value) +
        Dynamic.call_new_account_cost(account_exists, value) +
        call_memory_expansion_cost(state.memory, args_offset, args_size, ret_offset, ret_size)

    with {:ok, state_after_cost} <- MachineState.consume_gas(%{state | stack: stack}, call_cost),
         {:ok, db_after_transfer} <-
           Database.transfer(
             state_after_cost.db,
             state_after_cost.contract.address,
             address,
             value
           ) do
      {calldata, memory_after_read} =
        Memory.read_bytes(state_after_cost.memory, args_offset, args_size)

      forwarded_gas = Dynamic.call_forwarded_gas(state_after_cost.gas, gas_requested)

      case MachineState.consume_gas(
             %{state_after_cost | memory: memory_after_read},
             forwarded_gas
           ) do
        {:ok, state_after_forward} ->
          target_code = Database.get_code(db_after_transfer, address)

          if Precompiles.precompile?(address, state_after_forward.env.config) and
               target_code == <<>> do
            child_gas = forwarded_gas + Dynamic.call_stipend(value)

            case Precompiles.execute(address, calldata, child_gas, state_after_forward.env.config) do
              {:ok, output, gas_used} ->
                remaining_gas = child_gas - gas_used
                memory_result = write_return_data(memory_after_read, ret_offset, ret_size, output)
                {:ok, stack_after_call} = Stack.push(state_after_forward.stack, 1)
                state_after_touch = MachineState.touch_address(state_after_forward, address)

                {:ok,
                 state_after_touch
                 |> Map.put(:stack, stack_after_call)
                 |> Map.put(:memory, memory_result)
                 |> Map.put(:return_data, output)
                 |> Map.put(:gas, state_after_touch.gas + remaining_gas)
                 |> MachineState.advance_pc()}

              {:error, _reason} ->
                memory_result = write_return_data(memory_after_read, ret_offset, ret_size, <<>>)
                {:ok, stack_after_call} = Stack.push(state_after_forward.stack, 0)

                {:ok,
                 state_after_forward
                 |> Map.put(:stack, stack_after_call)
                 |> Map.put(:memory, memory_result)
                 |> Map.put(:return_data, <<>>)
                 |> MachineState.advance_pc()}
            end
          else
            state_after_touch = MachineState.touch_address(state_after_forward, address)

            child_contract =
              Contract.new(
                address: address,
                caller: state_after_forward.contract.address,
                callvalue: value,
                calldata: calldata,
                balances: state_after_forward.contract.balances
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
                is_static: state_after_touch.is_static,
                depth: state_after_touch.depth + 1,
                tracer: state_after_touch.tracer
              )

            child_result = Interpreter.run_loop(child_state)
            merged = Journal.merge_child_result(state_after_forward, child_result)

            memory_result =
              write_return_data(memory_after_read, ret_offset, ret_size, child_result.return_data)

            result_flag = if child_result.status == :stopped, do: 1, else: 0
            {:ok, stack_after_call} = Stack.push(state_after_forward.stack, result_flag)

            {:ok,
             merged
             |> Map.put(:stack, stack_after_call)
             |> Map.put(:memory, memory_result)
             |> Map.put(:return_data, child_result.return_data)
             |> Map.put(:gas, state_after_forward.gas + child_result.gas)
             |> MachineState.advance_pc()}
          end

        {:error, :out_of_gas, _halted_state} ->
          call_failed(state_after_cost, stack)
      end
    else
      {:error, :insufficient_balance} ->
        call_failed(%{state | stack: stack, gas: state.gas - call_cost}, stack)

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
    call_cost =
      if(charge_value_cost?, do: Dynamic.call_value_cost(callvalue), else: 0) +
        call_memory_expansion_cost(state.memory, args_offset, args_size, ret_offset, ret_size)

    with {:ok, state_after_cost} <- MachineState.consume_gas(%{state | stack: stack}, call_cost) do
      {calldata, memory_after_read} =
        Memory.read_bytes(state_after_cost.memory, args_offset, args_size)

      forwarded_gas = Dynamic.call_forwarded_gas(state_after_cost.gas, gas_requested)

      case MachineState.consume_gas(
             %{state_after_cost | memory: memory_after_read},
             forwarded_gas
           ) do
        {:ok, state_after_forward} ->
          child_gas =
            forwarded_gas + if(add_stipend?, do: Dynamic.call_stipend(callvalue), else: 0)

          target_code = Database.get_code(state_after_forward.db, address)

          if Precompiles.precompile?(address, state_after_forward.env.config) and
               target_code == <<>> do
            case Precompiles.execute(address, calldata, child_gas, state_after_forward.env.config) do
              {:ok, output, gas_used} ->
                remaining_gas = child_gas - gas_used
                memory_result = write_return_data(memory_after_read, ret_offset, ret_size, output)
                {:ok, stack_after_call} = Stack.push(state_after_forward.stack, 1)
                state_after_touch = MachineState.touch_address(state_after_forward, address)

                {:ok,
                 state_after_touch
                 |> Map.put(:stack, stack_after_call)
                 |> Map.put(:memory, memory_result)
                 |> Map.put(:return_data, output)
                 |> Map.put(:gas, state_after_touch.gas + remaining_gas)
                 |> MachineState.advance_pc()}

              {:error, _reason} ->
                memory_result = write_return_data(memory_after_read, ret_offset, ret_size, <<>>)
                {:ok, stack_after_call} = Stack.push(state_after_forward.stack, 0)

                {:ok,
                 state_after_forward
                 |> Map.put(:stack, stack_after_call)
                 |> Map.put(:memory, memory_result)
                 |> Map.put(:return_data, <<>>)
                 |> MachineState.advance_pc()}
            end
          else
            state_after_touch = MachineState.touch_address(state_after_forward, address)

            child_contract =
              Contract.new(
                address: state_after_forward.contract.address,
                caller: caller,
                callvalue: callvalue,
                calldata: calldata,
                balances: state_after_forward.contract.balances
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
                is_static: state_after_touch.is_static,
                depth: state_after_touch.depth + 1,
                tracer: state_after_touch.tracer
              )

            child_result = Interpreter.run_loop(child_state)
            merged = Journal.merge_child_result(state_after_forward, child_result)

            memory_result =
              write_return_data(memory_after_read, ret_offset, ret_size, child_result.return_data)

            result_flag = if child_result.status == :stopped, do: 1, else: 0
            {:ok, stack_after_call} = Stack.push(state_after_forward.stack, result_flag)

            {:ok,
             merged
             |> Map.put(:stack, stack_after_call)
             |> Map.put(:memory, memory_result)
             |> Map.put(:return_data, child_result.return_data)
             |> Map.put(:gas, state_after_forward.gas + child_result.gas)
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

  defp call_failed(state, stack) do
    {:ok, stack_after_call} = Stack.push(stack, 0)
    {:ok, %{state | stack: stack_after_call} |> MachineState.advance_pc()}
  end
end
