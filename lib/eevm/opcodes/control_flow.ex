defmodule EEVM.Opcodes.ControlFlow do
  @moduledoc """
  Opcodes for program counter manipulation and stack data loading.

  ## EVM Concepts

  This module covers everything that moves the program counter and loads data:

  - **Branching**: JUMP (0x56) and JUMPI (0x57) are the only branching
    instructions in the EVM — there is no native if/else or loop construct at
    the opcode level. The jump destination must be a JUMPDEST (0x5B) byte in the
    bytecode. This prevents jumping into the middle of PUSH data, which could
    be exploited to confuse disassemblers or bypass security checks.

  - **Stack loading (PUSH)**: PUSH0 (0x5F, EIP-3855) pushes zero without
    consuming any inline bytecode bytes. PUSH1-PUSH32 (0x60-0x7F) read the next
    1-32 bytes from bytecode and push the value. PUSH0 saves 1 byte of bytecode
    and 2 gas compared to PUSH1 0x00.

  - **Stack duplication (DUP)**: DUP1-DUP16 (0x80-0x8F) copy an item from deep
    in the stack and push the copy on top. DUP1 copies the top, DUP2 copies the
    second item, etc.

  - **Stack swapping (SWAP)**: SWAP1-SWAP16 (0x90-0x9F) exchange the top of
    stack with an item below it. SWAP1 swaps positions 0 and 1, SWAP16 swaps
    positions 0 and 16.

  PC (0x58) pushes the current program counter value. JUMPDEST (0x5B) is a
  no-op marker that costs 1 gas and marks a valid jump target.

  ## Elixir Learning Notes

  - Guard ranges (`when op >= 0x60 and op <= 0x7F`) match all PUSH opcodes in
    a single clause, avoiding 32 separate function heads.
  - Binary pattern matching (`MachineState.read_code/3`) extracts raw bytes
    from the bytecode binary with no intermediate parsing step.
  - DUP depth is derived by subtracting the base opcode (`op - 0x80`), and
    SWAP depth adds 1 (`op - 0x90 + 1`) to include the top-of-stack position.
  """

  alias EEVM.{MachineState, Stack}
  alias EEVM.Opcodes.Registry
  alias EEVM.Opcodes.Helpers

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

  # JUMPI — conditional jump. Pops destination and condition.
  # If condition is non-zero, validates and jumps. If zero, falls through.

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
  def execute(0x5F, state), do: Helpers.push_value(state, 0)

  # PUSH1-PUSH32 — read `n` bytes immediately following the current PC from
  # bytecode and push the value as a big-endian unsigned integer.
  # `Registry.push_bytes/1` derives the byte count from the opcode.
  # The PC advances by 1 (opcode) + n (push data) in one step.

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

  # DUP1-DUP16 — depth is 0-based relative to the top of stack.
  # DUP1 peeks at depth 0 (the top) and pushes a copy.
  # `op - 0x80` converts the opcode byte to the peek depth directly.

  def execute(op, state) when op >= 0x80 and op <= 0x8F do
    depth = op - 0x80

    with {:ok, value} <- Stack.peek(state.stack, depth),
         {:ok, new_stack} <- Stack.push(state.stack, value) do
      {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SWAP1-SWAP16 — swaps top of stack with the element at `depth`.
  # `op - 0x90 + 1` gives the depth: SWAP1 → 1, SWAP2 → 2, SWAP16 → 16.

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
