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
  alias EEVM.Crypto.Keccak
  alias EEVM.Database
  alias EEVM.Gas.Access
  alias EEVM.Gas.Dynamic
  alias EEVM.Gas.Memory, as: GasMemory
  alias EEVM.Interpreter.Instructions.Helpers
  alias EEVM.Interpreter.{MachineState, Memory, Stack}

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x31, state) do
    with {:ok, addr, s1} <- Helpers.pop_address(state.frame.stack) do
      {access_cost, state_after_access} =
        Access.address_access_cost(MachineState.update_frame(state, &%{&1 | stack: s1}), addr)

      case MachineState.consume_gas(state_after_access, access_cost) do
        {:ok, state_after_gas} ->
          balance = lookup_balance(state_after_gas, addr)

          case Stack.push(state_after_gas.frame.stack, balance) do
            {:ok, s2} ->
              {:ok,
               state_after_gas
               |> MachineState.update_frame(&%{&1 | stack: s2})
               |> MachineState.advance_pc()}

            {:error, reason} ->
              {:error, reason, state_after_gas}
          end

        {:error, :out_of_gas, halted_state} ->
          {:error, :out_of_gas, halted_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x3B, state) do
    with {:ok, addr, s1} <- Helpers.pop_address(state.frame.stack) do
      {access_cost, state_after_access} =
        Access.address_access_cost(MachineState.update_frame(state, &%{&1 | stack: s1}), addr)

      case MachineState.consume_gas(state_after_access, access_cost) do
        {:ok, state_after_gas} ->
          size = byte_size(Database.get_code(state_after_gas.db, addr))

          case Stack.push(state_after_gas.frame.stack, size) do
            {:ok, s2} ->
              {:ok,
               state_after_gas
               |> MachineState.update_frame(&%{&1 | stack: s2})
               |> MachineState.advance_pc()}

            {:error, reason} ->
              {:error, reason, state_after_gas}
          end

        {:error, :out_of_gas, halted_state} ->
          {:error, :out_of_gas, halted_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x3C, state) do
    with {:ok, addr, s1} <- Helpers.pop_address(state.frame.stack),
         {:ok, dest_offset, s2} <- Stack.pop(s1),
         {:ok, code_offset, s3} <- Stack.pop(s2),
         {:ok, length, s4} <- Stack.pop(s3) do
      {access_cost, state_after_access} =
        Access.address_access_cost(MachineState.update_frame(state, &%{&1 | stack: s4}), addr)

      case MachineState.consume_gas(state_after_access, access_cost) do
        {:ok, state_after_access_gas} ->
          if length == 0 do
            {:ok, state_after_access_gas |> MachineState.advance_pc()}
          else
            dynamic_cost =
              Dynamic.copy_cost(length) +
                GasMemory.memory_expansion_cost(
                  Memory.size(state_after_access_gas.frame.memory),
                  dest_offset,
                  length
                )

            case MachineState.consume_gas(state_after_access_gas, dynamic_cost) do
              {:ok, state_after_gas} ->
                new_memory =
                  Memory.write_slice(
                    state_after_gas.frame.memory,
                    dest_offset,
                    Database.get_code(state_after_gas.db, addr),
                    code_offset,
                    length
                  )

                {:ok,
                 state_after_gas
                 |> MachineState.update_frame(&%{&1 | memory: new_memory})
                 |> MachineState.advance_pc()}

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
    with {:ok, addr, s1} <- Helpers.pop_address(state.frame.stack) do
      {access_cost, state_after_access} =
        Access.address_access_cost(MachineState.update_frame(state, &%{&1 | stack: s1}), addr)

      case MachineState.consume_gas(state_after_access, access_cost) do
        {:ok, state_after_gas} ->
          # EIP-1052: 0 for an account that doesn't exist or is empty (EIP-161),
          # such as one a zero-value SELFDESTRUCT touched into existence.
          hash_value =
            if Database.account_empty?(state_after_gas.db, addr) do
              0
            else
              <<hash_int::unsigned-big-256>> =
                Keccak.hash_256(Database.get_code(state_after_gas.db, addr))

              hash_int
            end

          case Stack.push(state_after_gas.frame.stack, hash_value) do
            {:ok, s2} ->
              {:ok,
               state_after_gas
               |> MachineState.update_frame(&%{&1 | stack: s2})
               |> MachineState.advance_pc()}

            {:error, reason} ->
              {:error, reason, state_after_gas}
          end

        {:error, :out_of_gas, halted_state} ->
          {:error, :out_of_gas, halted_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x47, state) do
    balance = lookup_balance(state, state.frame.contract.address)
    Helpers.push_value(state, balance)
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}

  defp lookup_balance(state, address) do
    if Database.account_exists?(state.db, address) do
      Database.get_balance(state.db, address)
    else
      Contract.balance(state.frame.contract, address)
    end
  end
end
