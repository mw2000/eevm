defmodule EEVM.Opcodes.System do
  @moduledoc """
  Opcodes that terminate execution.

  ## EVM Concepts

  Every EVM execution must end with a terminating opcode. This module
  implements all four:

  - **STOP (0x00)**: Normal termination with no return data. The cheapest
    way to end a call.

  - **RETURN (0xF3)**: Normal termination with return data. Pops a memory
    offset and length, reads that slice from memory, and sets it as the
    return data for the caller. Successful — state changes are kept.

  - **REVERT (0xFD)**: Abnormal termination with return data. Same memory
    slice semantics as RETURN, but all state changes made during this call
    are rolled back. Commonly used to return ABI-encoded error data.

  - **INVALID (0xFE)**: Unconditional failure. Consumes all remaining gas
    and rolls back state. Solidity uses it as an unreachable marker — if
    execution reaches INVALID, something went seriously wrong.

  The key distinction: RETURN and REVERT both produce output data and can
  read from memory. The difference is only in the status code — `:stopped`
  vs `:reverted`. STOP and INVALID produce no output.

  ## Elixir Learning Notes

  - Status atoms (`:stopped`, `:reverted`, `:invalid`) passed to
    `MachineState.halt/2` let the executor and caller distinguish outcomes
    without pattern matching on error tuples.
  - RETURN and REVERT share identical structure — only the halt status atom
    differs. This highlights how small Elixir expressions can encode
    meaningful semantic differences.
  """

  alias EEVM.{Executor, Gas, MachineState, Memory, Stack, WorldState}
  alias EEVM.Context.Contract

  @doc """
  Dispatches a system opcode to its implementation.

  Called by the executor for STOP (0x00), RETURN (0xF3), REVERT (0xFD), and
  INVALID (0xFE). Always returns `{:ok, new_state}` with a halted
  `MachineState`. The status field on the returned state indicates how
  execution ended.
  """
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}

  # STOP — halt immediately. No stack interaction, no return data.

  def execute(0x00, state), do: {:ok, MachineState.halt(state, :stopped)}

  # RETURN — halt successfully and expose a memory slice as return data.
  # offset/length pop from the stack define the memory range to read.
  # Memory may expand to cover the range, which costs expansion gas.

  def execute(0xF3, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, length, s2} <- Stack.pop(s1),
         expansion_cost = Gas.memory_expansion_cost(Memory.size(state.memory), offset, length),
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

  # REVERT — identical memory semantics to RETURN, but the halt status is
  # :reverted. The caller sees this as a failed sub-call and rolls back any
  # storage or balance changes made during this execution.

  def execute(0xFD, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, length, s2} <- Stack.pop(s1),
         expansion_cost = Gas.memory_expansion_cost(Memory.size(state.memory), offset, length),
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

  # INVALID — marks an unreachable code path. Consumes all remaining gas.
  # The executor special-cases 0xFE to set static_cost = state.gas before
  # calling here, so gas is already drained by the time execute/2 runs.

  def execute(0xFE, state), do: {:ok, MachineState.halt(state, :invalid)}

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
      Gas.memory_expansion_cost(Memory.size(state.memory), offset, size) +
        if(salt == nil, do: 0, else: Gas.create2_hash_cost(size))

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
                deposit_cost = Gas.code_deposit_cost(byte_size(runtime_code))

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

  defp integer_to_binary(0), do: <<>>
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
end
