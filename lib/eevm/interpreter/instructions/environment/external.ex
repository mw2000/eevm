defmodule EEVM.Interpreter.Instructions.Environment.External do
  @moduledoc """
  External account inspection opcodes with EIP-2929 access cost tracking.

  These opcodes query other accounts' state (balance, code, code hash) and
  incur cold/warm access costs per EIP-2929. The first access to an address
  costs 2,600 gas (cold); subsequent accesses cost 100 gas (warm).

  Includes: BALANCE (0x31), EXTCODESIZE (0x3B), EXTCODECOPY (0x3C),
  EXTCODEHASH (0x3F), and SELFBALANCE (0x47).
  """

  alias EEVM.Context.Contract
  alias EEVM.Database
  alias EEVM.Gas.Access
  alias EEVM.Gas.Dynamic
  alias EEVM.Gas.Memory, as: GasMemory
  alias EEVM.Interpreter.Instructions.Helpers
  alias EEVM.Interpreter.{MachineState, Memory, Stack}

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x31, state) do
    with {:ok, addr, s1} <- Stack.pop(state.stack) do
      {access_cost, state_after_access} = Access.address_access_cost(%{state | stack: s1}, addr)

      case MachineState.consume_gas(state_after_access, access_cost) do
        {:ok, state_after_gas} ->
          balance = lookup_balance(state_after_gas, addr)

          case Stack.push(state_after_gas.stack, balance) do
            {:ok, s2} -> {:ok, %{state_after_gas | stack: s2} |> MachineState.advance_pc()}
            {:error, reason} -> {:error, reason, state_after_gas}
          end

        {:error, :out_of_gas, halted_state} ->
          {:error, :out_of_gas, halted_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x3B, state) do
    with {:ok, addr, s1} <- Stack.pop(state.stack) do
      {access_cost, state_after_access} = Access.address_access_cost(%{state | stack: s1}, addr)

      case MachineState.consume_gas(state_after_access, access_cost) do
        {:ok, state_after_gas} ->
          size = byte_size(Database.get_code(state_after_gas.db, addr))

          case Stack.push(state_after_gas.stack, size) do
            {:ok, s2} -> {:ok, %{state_after_gas | stack: s2} |> MachineState.advance_pc()}
            {:error, reason} -> {:error, reason, state_after_gas}
          end

        {:error, :out_of_gas, halted_state} ->
          {:error, :out_of_gas, halted_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x3C, state) do
    with {:ok, addr, s1} <- Stack.pop(state.stack),
         {:ok, dest_offset, s2} <- Stack.pop(s1),
         {:ok, code_offset, s3} <- Stack.pop(s2),
         {:ok, length, s4} <- Stack.pop(s3) do
      {access_cost, state_after_access} = Access.address_access_cost(%{state | stack: s4}, addr)

      case MachineState.consume_gas(state_after_access, access_cost) do
        {:ok, state_after_access_gas} ->
          if length == 0 do
            {:ok, state_after_access_gas |> MachineState.advance_pc()}
          else
            dynamic_cost =
              Dynamic.copy_cost(length) +
                GasMemory.memory_expansion_cost(
                  Memory.size(state_after_access_gas.memory),
                  dest_offset,
                  length
                )

            case MachineState.consume_gas(state_after_access_gas, dynamic_cost) do
              {:ok, state_after_gas} ->
                bytes = read_external_code(state_after_gas.db, addr, code_offset, length)

                new_memory =
                  bytes
                  |> :binary.bin_to_list()
                  |> Enum.with_index()
                  |> Enum.reduce(state_after_gas.memory, fn {byte, i}, mem ->
                    Memory.store_byte(mem, dest_offset + i, byte)
                  end)

                {:ok, %{state_after_gas | memory: new_memory} |> MachineState.advance_pc()}

              {:error, :out_of_gas, halted_state} ->
                {:error, :out_of_gas, halted_state}
            end
          end

        {:error, :out_of_gas, halted_state} ->
          {:error, :out_of_gas, halted_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x3F, state) do
    with {:ok, addr, s1} <- Stack.pop(state.stack) do
      {access_cost, state_after_access} = Access.address_access_cost(%{state | stack: s1}, addr)

      case MachineState.consume_gas(state_after_access, access_cost) do
        {:ok, state_after_gas} ->
          hash_value =
            if Database.account_exists?(state_after_gas.db, addr) do
              code = Database.get_code(state_after_gas.db, addr)
              hash = ExKeccak.hash_256(code)
              <<hash_int::unsigned-big-256>> = hash
              hash_int
            else
              0
            end

          case Stack.push(state_after_gas.stack, hash_value) do
            {:ok, s2} -> {:ok, %{state_after_gas | stack: s2} |> MachineState.advance_pc()}
            {:error, reason} -> {:error, reason, state_after_gas}
          end

        {:error, :out_of_gas, halted_state} ->
          {:error, :out_of_gas, halted_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x47, state) do
    balance = lookup_balance(state, state.contract.address)
    Helpers.push_value(state, balance)
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}

  defp lookup_balance(state, address) do
    if Database.account_exists?(state.db, address) do
      Database.get_balance(state.db, address)
    else
      Contract.balance(state.contract, address)
    end
  end

  defp read_external_code(db, address, offset, length) do
    code = Database.get_code(db, address)
    code_size = byte_size(code)

    if offset >= code_size do
      <<0::size(length * 8)>>
    else
      available = min(length, code_size - offset)
      chunk = binary_part(code, offset, available)
      padding_size = (length - available) * 8
      <<chunk::binary, 0::size(padding_size)>>
    end
  end
end
