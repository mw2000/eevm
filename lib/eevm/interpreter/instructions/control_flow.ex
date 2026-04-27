defmodule EEVM.Interpreter.Instructions.ControlFlow do
  @moduledoc """
  Branching, PC, JUMPDEST, PUSH0/PUSH1-32, DUP1-16, SWAP1-16.

  JUMP (0x56) and JUMPI (0x57) are the only branching opcodes; the destination
  must land on a JUMPDEST (0x5B) byte that is not part of PUSH immediate data.
  PUSH0 (0x5F, EIP-3855, Shanghai+) is `:invalid` on earlier forks.
  """

  alias EEVM.Interpreter.{MachineState, Stack}
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.Instructions.{Helpers, Registry}

  @doc """
  Dispatches one control-flow opcode against `state`.

  Handles JUMP, JUMPI, PC, JUMPDEST, PUSH0, PUSH1-PUSH32, DUP1-DUP16, and
  SWAP1-SWAP16.
  """
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}

  def execute(0x56, state) do
    with {:ok, dest, s1} <- Stack.pop(state.stack) do
      if Helpers.valid_jumpdest?(state.code, dest) do
        {:ok, %{state | stack: s1, pc: dest}}
      else
        {:error, :invalid_jump_destination, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x57, state) do
    with {:ok, dest, s1} <- Stack.pop(state.stack),
         {:ok, condition, s2} <- Stack.pop(s1) do
      if condition != 0 do
        if Helpers.valid_jumpdest?(state.code, dest) do
          {:ok, %{state | stack: s2, pc: dest}}
        else
          {:error, :invalid_jump_destination, state}
        end
      else
        {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x58, state), do: Helpers.push_value(state, state.pc)
  def execute(0x5B, state), do: {:ok, MachineState.advance_pc(state)}

  def execute(0x5F, %{config: %{hardfork: hardfork}} = state) do
    if HardforkConfig.enabled?(hardfork, :eip_3855) do
      Helpers.push_value(state, 0)
    else
      {:ok, MachineState.halt(state, :invalid)}
    end
  end

  def execute(op, state) when op >= 0x60 and op <= 0x7F do
    n = Registry.push_bytes(op)
    bytes = MachineState.read_code(state, state.pc + 1, n)

    value =
      bytes
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, acc -> acc * 256 + byte end)

    case Stack.push(state.stack, value) do
      {:ok, new_stack} ->
        {:ok, %{state | stack: new_stack} |> MachineState.advance_pc(1 + n)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def execute(op, state) when op >= 0x80 and op <= 0x8F do
    depth = op - 0x80

    with {:ok, value} <- Stack.peek(state.stack, depth),
         {:ok, new_stack} <- Stack.push(state.stack, value) do
      {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(op, state) when op >= 0x90 and op <= 0x9F do
    depth = op - 0x90 + 1

    case Stack.swap(state.stack, depth) do
      {:ok, new_stack} ->
        {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
