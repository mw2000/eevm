defmodule EEVM.Opcodes.System.Creation do
  @moduledoc """
  Contract creation opcodes.

  This module handles the most complex EVM operations — those that spawn nested
  execution frames and interact with the world state.

  ## Contract Creation

  - **CREATE** (0xF0) — deploys a new contract at an address derived from
    the sender's address and nonce (RLP-encoded, then Keccak-256 hashed).
  - **CREATE2** (0xF5) — deploys at a deterministic address derived from
    the sender, a salt value, and the initcode hash (EIP-1014).

  Both enforce EIP-3860 initcode size limits (`max_initcode_size = 49,152 bytes`)
  and EIP-170 runtime code size limits (`max_code_size = 24,576 bytes`).
  """

  @max_code_size 24_576
  @max_initcode_size 49_152
  @initcode_word_cost 2

  alias EEVM.{Database, Executor, HardforkConfig, MachineState, Memory, Stack}
  alias EEVM.Gas.Dynamic
  alias EEVM.Gas.Memory, as: GasMemory
  alias EEVM.Context.Contract
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
        creator = state_after_cost.contract.address
        nonce = Database.get_nonce(state_after_cost.db, creator)

        db_after_nonce =
          Database.increment_nonce(state_after_cost.db, creator)

        if HardforkConfig.enabled?(state_after_cost.config.hardfork, :eip_3860) and
             size > @max_initcode_size do
          create_failed(%{state_after_cost | db: db_after_nonce}, stack)
        else
          initcode_cost =
            if HardforkConfig.enabled?(state_after_cost.config.hardfork, :eip_3860),
              do: @initcode_word_cost * div(size + 31, 32),
              else: 0

          case MachineState.consume_gas(state_after_cost, initcode_cost) do
            {:ok, state_after_initcode_cost} ->
              {init_code, memory_after_read} =
                Memory.read_bytes(state_after_initcode_cost.memory, offset, size)

              new_address =
                if salt == nil,
                  do: derive_create_address(creator, nonce),
                  else: derive_create2_address(creator, salt, init_code)

              state_after_touch =
                MachineState.touch_address(state_after_initcode_cost, new_address)

              can_create = can_create_account?(db_after_nonce, new_address)

              if can_create do
                case Database.transfer(db_after_nonce, creator, new_address, value) do
                  {:ok, db_after_transfer} ->
                    child_contract =
                      Contract.new(
                        address: new_address,
                        caller: creator,
                        callvalue: value,
                        calldata: <<>>,
                        balances: state_after_initcode_cost.contract.balances
                      )

                    child_state =
                      MachineState.new(init_code,
                        gas: state_after_initcode_cost.gas,
                        db: db_after_transfer,
                        tx: state_after_touch.tx,
                        block: state_after_touch.block,
                        contract: child_contract,
                        config: state_after_touch.config,
                        touched_addresses: state_after_touch.touched_addresses,
                        accessed_addresses: state_after_touch.accessed_addresses,
                        accessed_storage_keys: state_after_touch.accessed_storage_keys,
                        created_addresses: state_after_touch.created_addresses,
                        is_static: state_after_touch.is_static,
                        depth: state_after_touch.depth + 1,
                        tracer: state_after_touch.tracer
                      )

                    child_result = Executor.run_loop(child_state)
                    deployment_success = child_result.status == :stopped

                    post_child_fail_state = %{
                      state_after_touch
                      | db: db_after_nonce,
                        tracer: child_result.tracer
                    }

                    if deployment_success do
                      runtime_code = child_result.return_data

                      if HardforkConfig.enabled?(child_result.config.hardfork, :eip_170) and
                           byte_size(runtime_code) > @max_code_size do
                        create_failed(post_child_fail_state, stack)
                      else
                        # EIP-3541 (London+): reject runtime code whose first byte is 0xEF.
                        # The 0xEF prefix is reserved for the EVM Object Format (EOF).
                        # This check runs after EIP-170 size validation and after init code
                        # execution -- so init code gas is already consumed but no code is
                        # deposited. Empty runtime code is explicitly allowed.
                        if HardforkConfig.enabled?(child_result.config.hardfork, :eip_3541) and
                             reject_eip_3541_runtime_code?(runtime_code) do
                          create_failed(post_child_fail_state, stack)
                        else
                          deposit_cost = Dynamic.code_deposit_cost(byte_size(runtime_code))

                          if child_result.gas >= deposit_cost do
                            db_after_deploy =
                              child_result.db
                              |> Database.put_code(new_address, runtime_code)
                              |> Database.set_nonce(new_address, 1)

                            {:ok, stack_after_create} = Stack.push(stack, new_address)

                            created_addresses_after =
                              MapSet.put(child_result.created_addresses, new_address)

                            {:ok,
                             state_after_initcode_cost
                             |> Map.put(:stack, stack_after_create)
                             |> Map.put(:memory, memory_after_read)
                             |> Map.put(:db, db_after_deploy)
                             |> Map.put(
                               :logs,
                               state_after_initcode_cost.logs ++ child_result.logs
                             )
                             |> Map.put(:accessed_addresses, child_result.accessed_addresses)
                             |> Map.put(
                               :accessed_storage_keys,
                               child_result.accessed_storage_keys
                             )
                             |> Map.put(:created_addresses, created_addresses_after)
                             |> Map.put(:touched_addresses, child_result.touched_addresses)
                             |> Map.put(:gas, child_result.gas - deposit_cost)
                             |> Map.put(:return_data, child_result.return_data)
                             |> Map.put(:tracer, child_result.tracer)
                             |> MachineState.advance_pc()}
                          else
                            create_failed(post_child_fail_state, stack)
                          end
                        end
                      end
                    else
                      create_failed(
                        post_child_fail_state,
                        stack
                      )
                    end

                  {:error, :insufficient_balance} ->
                    create_failed(
                      %{state_after_touch | db: db_after_nonce},
                      stack
                    )
                end
              else
                create_failed(
                  %{state_after_touch | db: db_after_nonce},
                  stack
                )
              end

            {:error, :out_of_gas, halted_state} ->
              {:error, :out_of_gas, halted_state}
          end
        end

      {:error, :out_of_gas, halted_state} ->
        {:error, :out_of_gas, halted_state}
    end
  end

  defp can_create_account?(db, address) do
    account = Database.get_account(db, address)

    case account do
      nil ->
        true

      _ ->
        Database.get_nonce(db, address) == 0 and
          Database.get_code(db, address) == <<>>
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

  # EIP-3541 (London): returns true when runtime code must be rejected.
  # CREATE/CREATE2 cannot deploy bytecode whose first byte is 0xEF — that
  # prefix is reserved for the EVM Object Format (EOF). Empty runtime code
  # is explicitly allowed; only a non-empty 0xEF-prefixed result is rejected.
  @spec reject_eip_3541_runtime_code?(binary()) :: boolean()
  defp reject_eip_3541_runtime_code?(runtime_code) do
    byte_size(runtime_code) > 0 and :binary.first(runtime_code) == 0xEF
  end

  defp create_failed(state, stack) do
    {:ok, stack_after_create} = Stack.push(stack, 0)
    {:ok, %{state | stack: stack_after_create} |> MachineState.advance_pc()}
  end
end
