defmodule EEVM.Opcodes.Logging do
  @moduledoc """
  EVM logging opcodes — LOG0 through LOG4.

  ## EVM Concepts

  - LOG instructions emit event logs that are stored in transaction receipts.
  - Each log contains the emitting contract address, a data payload from memory,
    and 0–4 indexed topic values from the stack.
  - Topics are 256-bit values used for efficient off-chain filtering (e.g. event signatures).
  - Gas cost: 375 base + 375 per topic + 8 per byte of data + memory expansion.

  ## Elixir Learning Notes

  - We use pattern matching on the topic count (0–4) to dispatch LOG variants.
  - Logs accumulate in `state.logs` as a list of maps, preserving insertion order.
  - `binary_part/3` extracts a slice from a binary — used to read log data from memory bytes.
  """

  alias EEVM.{MachineState, Memory, Stack}
  alias EEVM.Gas.Dynamic
  alias EEVM.Gas.Memory, as: GasMemory

  @doc """
  Dispatches a LOG opcode (LOG0–LOG4) to the matching topic-count handler.
  """
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}
  def execute(0xA0, state), do: execute_log(state, 0)
  def execute(0xA1, state), do: execute_log(state, 1)
  def execute(0xA2, state), do: execute_log(state, 2)
  def execute(0xA3, state), do: execute_log(state, 3)
  def execute(0xA4, state), do: execute_log(state, 4)

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}

  defp execute_log(state, topic_count) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, size, s2} <- Stack.pop(s1),
         {:ok, topics, s3} <- pop_topics(s2, topic_count, []) do
      dynamic_cost =
        Dynamic.log_cost(topic_count, size) +
          GasMemory.memory_expansion_cost(Memory.size(state.memory), offset, size)

      case MachineState.consume_gas(%{state | stack: s3}, dynamic_cost) do
        {:ok, s4} ->
          {data, new_memory} = Memory.read_bytes(s4.memory, offset, size)

          log_entry = %{
            address: s4.contract.address,
            data: data,
            topics: topics
          }

          s5 = %{s4 | memory: new_memory, logs: s4.logs ++ [log_entry]}
          {:ok, MachineState.advance_pc(s5)}

        {:error, :out_of_gas, halted_state} ->
          {:error, :out_of_gas, halted_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp pop_topics(stack, 0, acc), do: {:ok, Enum.reverse(acc), stack}

  defp pop_topics(stack, n, acc) do
    case Stack.pop(stack) do
      {:ok, value, new_stack} -> pop_topics(new_stack, n - 1, [value | acc])
      error -> error
    end
  end
end
