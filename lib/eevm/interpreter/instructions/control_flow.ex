defmodule EEVM.Interpreter.Instructions.ControlFlow do
  @moduledoc """
  Opcodes for program counter manipulation and stack data loading.

  Covers:

  - **Branching**: JUMP (0x56), JUMPI (0x57) — destination must land on a
    JUMPDEST (0x5B) byte.
  - **PUSH**: PUSH0 (0x5F, EIP-3855), PUSH1-PUSH32 (0x60-0x7F).
  - **DUP**: DUP1-DUP16 (0x80-0x8F).
  - **SWAP**: SWAP1-SWAP16 (0x90-0x9F).
  - **PC** (0x58) and **JUMPDEST** (0x5B).
  """

  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.Instructions.Helpers
  alias EEVM.Interpreter.Instructions.Registry
  alias EEVM.Interpreter.{MachineState, Stack}

  @doc """
  Dispatches a control flow opcode to its implementation.

  Called by the executor for JUMP, JUMPI, PC, JUMPDEST, PUSH0, PUSH1-PUSH32,
  DUP1-DUP16, and SWAP1-SWAP16. Returns `{:ok, new_state}` on success or
  `{:error, reason, state}` on failure.
  """
  @spec execute(non_neg_integer(), MachineState.t()) ::
          {:ok, MachineState.t()} | {:error, atom(), MachineState.t()}

  # JUMP — unconditional jump. Pops the destination and validates it is a
  # JUMPDEST byte in the bytecode. Any other destination is an error.

  def execute(0x56, state) do
    with {:ok, dest, s1} <- Stack.pop(state.frame.stack) do
      if Helpers.valid_jumpdest?(state.frame.code, dest) do
        {:ok, MachineState.update_frame(state, &%{&1 | stack: s1, pc: dest})}
      else
        {:error, :invalid_jump_destination, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # JUMPI — conditional jump. Pops destination and condition.
  # If condition is non-zero, validates and jumps. If zero, falls through.

  def execute(0x57, state) do
    with {:ok, dest, s1} <- Stack.pop(state.frame.stack),
         {:ok, condition, s2} <- Stack.pop(s1) do
      if condition != 0 do
        if Helpers.valid_jumpdest?(state.frame.code, dest) do
          {:ok, MachineState.update_frame(state, &%{&1 | stack: s2, pc: dest})}
        else
          {:error, :invalid_jump_destination, state}
        end
      else
        {:ok, state |> MachineState.update_frame(&%{&1 | stack: s2}) |> MachineState.advance_pc()}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def execute(0x58, state), do: Helpers.push_value(state, state.frame.pc)
  def execute(0x5B, state), do: {:ok, MachineState.advance_pc(state)}
  # PUSH0 (EIP-3855, Shanghai+): pushes the constant 0 onto the stack without
  # consuming any inline bytecode bytes. Saves 1 byte and 2 gas vs PUSH1 0x00.
  # Pre-Shanghai, 0x5F is an undefined opcode and halts with :invalid.
  def execute(0x5F, %{env: %{config: %{hardfork: hardfork}}} = state) do
    if HardforkConfig.enabled?(hardfork, :eip_3855) do
      Helpers.push_value(state, 0)
    else
      {:ok, MachineState.halt(state, :invalid)}
    end
  end

  # PUSH1-PUSH32 — read `n` bytes immediately following the current PC from
  # bytecode and push the value as a big-endian unsigned integer.
  # `Registry.push_bytes/1` derives the byte count from the opcode.
  # The PC advances by 1 (opcode) + n (push data) in one step.

  def execute(op, state) when op >= 0x60 and op <= 0x7F do
    n = Registry.push_bytes(op)
    bytes = MachineState.read_code(state, state.frame.pc + 1, n)

    value =
      bytes
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, acc -> acc * 256 + byte end)

    case Stack.push(state.frame.stack, value) do
      {:ok, new_stack} ->
        {:ok,
         state
         |> MachineState.update_frame(&%{&1 | stack: new_stack})
         |> MachineState.advance_pc(1 + n)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # DUP1-DUP16 — depth is 0-based relative to the top of stack.
  # DUP1 peeks at depth 0 (the top) and pushes a copy.
  # `op - 0x80` converts the opcode byte to the peek depth directly.

  def execute(op, state) when op >= 0x80 and op <= 0x8F do
    depth = op - 0x80

    with {:ok, value} <- Stack.peek(state.frame.stack, depth),
         {:ok, new_stack} <- Stack.push(state.frame.stack, value) do
      {:ok,
       state
       |> MachineState.update_frame(&%{&1 | stack: new_stack})
       |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SWAP1-SWAP16 — swaps top of stack with the element at `depth`.
  # `op - 0x90 + 1` gives the depth: SWAP1 → 1, SWAP2 → 2, SWAP16 → 16.

  def execute(op, state) when op >= 0x90 and op <= 0x9F do
    depth = op - 0x90 + 1

    case Stack.swap(state.frame.stack, depth) do
      {:ok, new_stack} ->
        {:ok,
         state
         |> MachineState.update_frame(&%{&1 | stack: new_stack})
         |> MachineState.advance_pc()}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def execute(_opcode, state), do: {:ok, MachineState.halt(state, :invalid)}
end
