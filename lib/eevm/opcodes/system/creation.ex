defmodule EEVM.Opcodes.System.Creation do
  @moduledoc false

  alias EEVM.{Executor, MachineState, Memory, Stack, WorldState}
  alias EEVM.Gas.Dynamic
  alias EEVM.Gas.Memory, as: GasMemory
  alias EEVM.Context.Contract

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0xF0, state) do
    with {:ok, value, s1} <- Stack.pop(state.stack),
         {:ok, offset, s2} <- Stack.pop(s1),
         {:ok, size, s3} <- Stack.pop(s2) do
      execute_create(state, s3, value, offset, size, nil)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0xF5, state) do
    with {:ok, value, s1} <- Stack.pop(state.stack),
         {:ok, offset, s2} <- Stack.pop(s1),
         {:ok, size, s3} <- Stack.pop(s2),
         {:ok, salt, s4} <- Stack.pop(s3) do
      execute_create(state, s4, value, offset, size, salt)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

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

  defp execute_create(state, stack, value, offset, size, salt) do
    cond do
      state.depth >= 1024 ->
        create_failed(state, stack)

      state.is_static ->
        create_failed(state, stack)

      true ->
        execute_create_inner(state, stack, value, offset, size, salt)
    end
  end

  defp execute_create_inner(state, stack, value, offset, size, salt) do
    extra_cost =
      GasMemory.memory_expansion_cost(Memory.size(state.memory), offset, size) +
        if(salt == nil, do: 0, else: Dynamic.create2_hash_cost(size))

    case MachineState.consume_gas(%{state | stack: stack}, extra_cost) do
      {:ok, state_after_cost} ->
        {init_code, memory_after_read} = Memory.read_bytes(state_after_cost.memory, offset, size)

        creator = state_after_cost.contract.address
        nonce = WorldState.get_nonce(state_after_cost.world_state, creator)

        world_state_after_nonce =
          WorldState.increment_nonce(state_after_cost.world_state, creator)

        new_address =
          if salt == nil,
            do: derive_create_address(creator, nonce),
            else: derive_create2_address(creator, salt, init_code)

        can_create = can_create_account?(world_state_after_nonce, new_address)

        if can_create do
          case WorldState.transfer(world_state_after_nonce, creator, new_address, value) do
            {:ok, world_state_after_transfer} ->
              child_contract =
                Contract.new(
                  address: new_address,
                  caller: creator,
                  callvalue: value,
                  calldata: <<>>,
                  balances: state_after_cost.contract.balances
                )

              child_state =
                MachineState.new(init_code,
                  gas: state_after_cost.gas,
                  storage: state_after_cost.storage,
                  tx: state_after_cost.tx,
                  block: state_after_cost.block,
                  contract: child_contract,
                  world_state: world_state_after_transfer,
                  is_static: state_after_cost.is_static,
                  depth: state_after_cost.depth + 1
                )

              child_result = Executor.run_loop(child_state)
              deployment_success = child_result.status == :stopped

              if deployment_success do
                runtime_code = child_result.return_data
                deposit_cost = Dynamic.code_deposit_cost(byte_size(runtime_code))

                if child_result.gas >= deposit_cost do
                  world_state_after_deploy =
                    child_result.world_state
                    |> WorldState.put_code(new_address, runtime_code)
                    |> WorldState.set_nonce(new_address, 1)

                  {:ok, stack_after_create} = Stack.push(stack, new_address)

                  {:ok,
                   state_after_cost
                   |> Map.put(:stack, stack_after_create)
                   |> Map.put(:memory, memory_after_read)
                   |> Map.put(:world_state, world_state_after_deploy)
                   |> Map.put(:storage, child_result.storage)
                   |> Map.put(:logs, state_after_cost.logs ++ child_result.logs)
                   |> Map.put(:gas, child_result.gas - deposit_cost)
                   |> Map.put(:return_data, child_result.return_data)
                   |> MachineState.advance_pc()}
                else
                  create_failed(%{state_after_cost | world_state: world_state_after_nonce}, stack)
                end
              else
                create_failed(%{state_after_cost | world_state: world_state_after_nonce}, stack)
              end

            {:error, :insufficient_balance} ->
              create_failed(%{state_after_cost | world_state: world_state_after_nonce}, stack)
          end
        else
          create_failed(%{state_after_cost | world_state: world_state_after_nonce}, stack)
        end

      {:error, :out_of_gas, halted_state} ->
        {:error, :out_of_gas, halted_state}
    end
  end

  defp can_create_account?(world_state, address) do
    account = WorldState.get_account(world_state, address)

    case account do
      nil ->
        true

      _ ->
        WorldState.get_nonce(world_state, address) == 0 and
          WorldState.get_code(world_state, address) == <<>>
    end
  end

  defp derive_create_address(sender, nonce) do
    sender_bytes = <<sender::unsigned-big-160>>
    payload = rlp_encode_list([rlp_encode_bytes(sender_bytes), rlp_encode_integer(nonce)])
    <<_::binary-size(12), address::unsigned-big-160>> = ExKeccak.hash_256(payload)
    address
  end

  defp derive_create2_address(sender, salt, init_code) do
    sender_bytes = <<sender::unsigned-big-160>>
    salt_bytes = <<salt::unsigned-big-256>>
    init_hash = ExKeccak.hash_256(init_code)
    data = <<0xFF, sender_bytes::binary, salt_bytes::binary, init_hash::binary>>
    <<_::binary-size(12), address::unsigned-big-160>> = ExKeccak.hash_256(data)
    address
  end

  defp rlp_encode_integer(0), do: <<0x80>>

  defp rlp_encode_integer(value) do
    value
    |> integer_to_binary()
    |> rlp_encode_bytes()
  end

  defp integer_to_binary(value), do: :binary.encode_unsigned(value)

  defp rlp_encode_bytes(<<byte>>) when byte < 0x80, do: <<byte>>

  defp rlp_encode_bytes(bytes) do
    length = byte_size(bytes)

    if length <= 55 do
      <<0x80 + length, bytes::binary>>
    else
      length_bytes = :binary.encode_unsigned(length)
      <<0xB7 + byte_size(length_bytes), length_bytes::binary, bytes::binary>>
    end
  end

  defp rlp_encode_list(items) do
    payload = IO.iodata_to_binary(items)
    length = byte_size(payload)

    if length <= 55 do
      <<0xC0 + length, payload::binary>>
    else
      length_bytes = :binary.encode_unsigned(length)
      <<0xF7 + byte_size(length_bytes), length_bytes::binary, payload::binary>>
    end
  end

  defp create_failed(state, stack) do
    {:ok, stack_after_create} = Stack.push(stack, 0)
    {:ok, %{state | stack: stack_after_create} |> MachineState.advance_pc()}
  end

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
    world_state = state.world_state
    account_exists = WorldState.account_exists?(world_state, address)

    call_cost =
      Dynamic.call_value_cost(value) +
        Dynamic.call_new_account_cost(account_exists, value) +
        call_memory_expansion_cost(state.memory, args_offset, args_size, ret_offset, ret_size)

    with {:ok, state_after_cost} <- MachineState.consume_gas(%{state | stack: stack}, call_cost),
         {:ok, world_state_after_transfer} <-
           WorldState.transfer(
             state_after_cost.world_state,
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
          target_code = WorldState.get_code(world_state_after_transfer, address)

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
              storage: state_after_forward.storage,
              tx: state_after_forward.tx,
              block: state_after_forward.block,
              contract: child_contract,
              world_state: world_state_after_transfer,
              is_static: state_after_forward.is_static,
              depth: state_after_forward.depth + 1
            )

          child_result = Executor.run_loop(child_state)
          call_succeeded = child_result.status == :stopped

          world_state_result =
            if call_succeeded,
              do: child_result.world_state,
              else: state_after_forward.world_state

          storage_result =
            if call_succeeded,
              do: child_result.storage,
              else: state_after_forward.storage

          logs_result =
            if call_succeeded,
              do: state_after_forward.logs ++ child_result.logs,
              else: state_after_forward.logs

          memory_result =
            write_return_data(memory_after_read, ret_offset, ret_size, child_result.return_data)

          result_flag = if(call_succeeded, do: 1, else: 0)
          {:ok, stack_after_call} = Stack.push(state_after_forward.stack, result_flag)

          {:ok,
           state_after_forward
           |> Map.put(:stack, stack_after_call)
           |> Map.put(:memory, memory_result)
           |> Map.put(:return_data, child_result.return_data)
           |> Map.put(:world_state, world_state_result)
           |> Map.put(:storage, storage_result)
           |> Map.put(:logs, logs_result)
           |> Map.put(:gas, state_after_forward.gas + child_result.gas)
           |> MachineState.advance_pc()}

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
