defmodule EEVM.Interpreter.Instructions.Environment.Simple do
  @moduledoc """
  Simple environment opcodes that read a single value from the execution context.

  These opcodes push one value onto the stack with no dynamic gas cost beyond
  the static base. They read from the transaction, block, or contract context.

  Includes: ADDRESS, ORIGIN, CALLER, CALLVALUE, CALLDATASIZE, CODESIZE,
  GASPRICE, RETURNDATASIZE, COINBASE, TIMESTAMP, NUMBER, PREVRANDAO,
  GASLIMIT, CHAINID, BASEFEE, BLOBBASEFEE, GAS, BLOCKHASH, and BLOBHASH.
  """

  alias EEVM.{BlockEnv, Database}
  alias EEVM.Interpreter.Instructions.Helpers
  alias EEVM.Interpreter.{MachineState, Stack}

  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0x30, state), do: Helpers.push_value(state, state.frame.contract.address)
  def execute(0x32, state), do: Helpers.push_value(state, state.env.tx.origin)
  def execute(0x33, state), do: Helpers.push_value(state, state.frame.contract.caller)
  def execute(0x34, state), do: Helpers.push_value(state, state.frame.contract.callvalue)

  def execute(0x36, state),
    do: Helpers.push_value(state, byte_size(state.frame.contract.calldata))

  def execute(0x38, state), do: Helpers.push_value(state, byte_size(state.frame.code))
  def execute(0x3A, state), do: Helpers.push_value(state, state.env.tx.gas_price)
  def execute(0x3D, state), do: Helpers.push_value(state, byte_size(state.frame.return_data))
  def execute(0x41, state), do: Helpers.push_value(state, state.env.block.coinbase)
  def execute(0x42, state), do: Helpers.push_value(state, state.env.block.timestamp)
  def execute(0x43, state), do: Helpers.push_value(state, state.env.block.number)
  def execute(0x44, state), do: Helpers.push_value(state, state.env.block.prev_randao)
  def execute(0x45, state), do: Helpers.push_value(state, state.env.block.gas_limit)
  def execute(0x46, state), do: Helpers.push_value(state, state.env.config.chain_id)
  def execute(0x48, state), do: Helpers.push_value(state, state.env.block.base_fee)
  def execute(0x4A, state), do: Helpers.push_value(state, state.env.block.blob_base_fee)
  def execute(0x5A, state), do: Helpers.push_value(state, state.frame.gas)

  def execute(0x40, state) do
    with {:ok, block_num, s1} <- Stack.pop(state.frame.stack),
         hash = block_hash(state, block_num),
         {:ok, s2} <- Stack.push(s1, hash) do
      {:ok, state |> MachineState.update_frame(&%{&1 | stack: s2}) |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x49, state) do
    with {:ok, index, s1} <- Stack.pop(state.frame.stack) do
      value = Enum.at(state.env.tx.blob_hashes, index, 0)

      case Stack.push(s1, value) do
        {:ok, s2} ->
          {:ok,
           state |> MachineState.update_frame(&%{&1 | stack: s2}) |> MachineState.advance_pc()}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}

  # A recent block's hash comes from the block environment, or else from the
  # database backend (`c:EEVM.Database.block_hash/2`).
  defp block_hash(state, block_num) do
    case BlockEnv.hash(state.env.block, block_num) do
      0 when block_num < state.env.block.number and block_num + 256 >= state.env.block.number ->
        case Database.block_hash(state.db, block_num) do
          <<hash::unsigned-big-256>> -> hash
          nil -> 0
        end

      hash ->
        hash
    end
  end
end
