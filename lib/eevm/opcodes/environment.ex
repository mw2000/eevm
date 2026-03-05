defmodule EEVM.Opcodes.Environment do
  @moduledoc """
  Opcodes that read execution environment and blockchain context.

  ## EVM Concepts

  Environment opcodes are read-only — they push contextual data onto the stack
  without modifying any state. They fall into four groups:

  - **Transaction context**: ORIGIN (0x32) is the original EOA that signed the
    transaction. CALLER (0x33) is the immediate sender of the current call (can be
    a contract). CALLVALUE (0x34) is the ETH sent with the call, in wei.
    GASPRICE (0x3A) is the gas price set by the transaction.

  - **Block context**: COINBASE (0x41) is the miner/validator address.
    TIMESTAMP (0x42) and NUMBER (0x43) describe the current block. PREVRANDAO
    (0x44) replaced DIFFICULTY post-Merge. GASLIMIT (0x45), CHAINID (0x46), and
    BASEFEE (0x48) round out the block-level data.

  - **Contract context**: ADDRESS (0x30) is the address of the currently executing
    contract. BALANCE (0x31) looks up any address's ETH balance. SELFBALANCE
    (0x47) is a cheaper shortcut for the executing contract's own balance.
    CODESIZE (0x38) returns the length of the current contract's bytecode.

  - **Calldata**: CALLDATALOAD (0x35) reads 32 bytes from calldata starting at a
    given offset, zero-padding if the offset is near the end. CALLDATASIZE (0x36)
    returns the total calldata length. CALLDATACOPY (0x37) writes a slice of
    calldata into memory, expanding memory as needed. GAS (0x5A) returns the
    remaining gas at the time the opcode executes.

  BLOCKHASH (0x40) retrieves the hash of a recent block. Only the last 256 blocks
  are accessible — older requests return 0.

  ## Elixir Learning Notes

  - Most opcodes here are single-expression functions using `Helpers.push_value/2`,
    which pushes a value and advances the program counter in one step.
  - Struct field access (`state.block.coinbase`, `state.contract.caller`) reads
    directly from nested structs — no getter functions needed.
  - CALLDATACOPY is the most complex: it chains `with` for stack pops, checks gas,
    then builds the bytes via a list comprehension with bounds checking.
  """

  alias EEVM.{Gas, MachineState, Memory, Stack}
  alias EEVM.Context.{Block, Contract}
  alias EEVM.Opcodes.Helpers

  @doc """
  Dispatches an environment opcode to its implementation.

  Called by the executor for opcodes in the ranges 0x30-0x3D, 0x40-0x48, and
  0x5A. Returns `{:ok, new_state}` on success or `{:error, reason, state}` on
  failure. An unrecognized opcode halts with `:invalid`.
  """
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}

  def execute(0x30, state), do: Helpers.push_value(state, state.contract.address)

  def execute(0x31, state) do
    with {:ok, addr, s1} <- Stack.pop(state.stack),
         balance = Contract.balance(state.contract, addr),
         {:ok, s2} <- Stack.push(s1, balance) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x32, state), do: Helpers.push_value(state, state.tx.origin)
  def execute(0x33, state), do: Helpers.push_value(state, state.contract.caller)
  def execute(0x34, state), do: Helpers.push_value(state, state.contract.callvalue)

  # CALLDATALOAD — read 32 bytes from calldata starting at `offset`.
  # If the offset is past the end of calldata, the remaining bytes are zero-padded.
  # This means CALLDATALOAD always pushes a full 32-byte value regardless of input size.

  def execute(0x35, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         value = Contract.calldata_load(state.contract, offset),
         {:ok, s2} <- Stack.push(s1, value) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x36, state), do: Helpers.push_value(state, byte_size(state.contract.calldata))

  # CALLDATACOPY — copy `length` bytes of calldata starting at `data_offset`
  # into memory at `dest_offset`. Out-of-bounds calldata bytes are filled with 0.
  # Memory is expanded before the copy and the expansion gas is charged up front.

  def execute(0x37, state) do
    with {:ok, dest_offset, s1} <- Stack.pop(state.stack),
         {:ok, data_offset, s2} <- Stack.pop(s1),
         {:ok, length, s3} <- Stack.pop(s2) do
      if length == 0 do
        {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
      else
        expansion_cost = Gas.memory_expansion_cost(Memory.size(state.memory), dest_offset, length)

        case MachineState.consume_gas(%{state | stack: s3}, expansion_cost) do
          {:ok, state_after_gas} ->
            calldata = state_after_gas.contract.calldata
            cd_size = byte_size(calldata)

            bytes =
              for i <- 0..(length - 1), into: <<>> do
                if data_offset + i < cd_size do
                  <<:binary.at(calldata, data_offset + i)>>
                else
                  <<0>>
                end
              end

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
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x38, state), do: Helpers.push_value(state, byte_size(state.code))
  def execute(0x3A, state), do: Helpers.push_value(state, state.tx.gasprice)
  def execute(0x3D, state), do: Helpers.push_value(state, byte_size(state.return_data))

  def execute(0x3E, state) do
    with {:ok, dest_offset, s1} <- Stack.pop(state.stack),
         {:ok, data_offset, s2} <- Stack.pop(s1),
         {:ok, length, s3} <- Stack.pop(s2) do
      cond do
        length == 0 ->
          {:ok, MachineState.advance_pc(%{state | stack: s3})}

        data_offset + length > byte_size(state.return_data) ->
          {:ok, MachineState.halt(%{state | stack: s3}, :reverted)}

        true ->
          dynamic_cost =
            Gas.copy_cost(length) +
              Gas.memory_expansion_cost(Memory.size(state.memory), dest_offset, length)

          case MachineState.consume_gas(%{state | stack: s3}, dynamic_cost) do
            {:ok, s4} ->
              bytes = binary_part(s4.return_data, data_offset, length)

              new_memory =
                bytes
                |> :binary.bin_to_list()
                |> Enum.with_index()
                |> Enum.reduce(s4.memory, fn {byte, i}, mem ->
                  Memory.store_byte(mem, dest_offset + i, byte)
                end)

              {:ok, MachineState.advance_pc(%{s4 | memory: new_memory})}

            {:error, :out_of_gas, halted_state} ->
              {:error, :out_of_gas, halted_state}
          end
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # BLOCKHASH — returns the hash of a past block by number.
  # Only the 256 most recent blocks are available. Anything older — or the
  # current block itself — returns 0. The lookup is delegated to Block.hash/2.

  def execute(0x40, state) do
    with {:ok, block_num, s1} <- Stack.pop(state.stack),
         hash = Block.hash(state.block, block_num),
         {:ok, s2} <- Stack.push(s1, hash) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x41, state), do: Helpers.push_value(state, state.block.coinbase)
  def execute(0x42, state), do: Helpers.push_value(state, state.block.timestamp)
  def execute(0x43, state), do: Helpers.push_value(state, state.block.number)
  def execute(0x44, state), do: Helpers.push_value(state, state.block.prevrandao)
  def execute(0x45, state), do: Helpers.push_value(state, state.block.gaslimit)
  def execute(0x46, state), do: Helpers.push_value(state, state.block.chain_id)

  def execute(0x47, state) do
    balance = Contract.balance(state.contract, state.contract.address)
    Helpers.push_value(state, balance)
  end

  def execute(0x48, state), do: Helpers.push_value(state, state.block.basefee)
  def execute(0x5A, state), do: Helpers.push_value(state, state.gas)

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
