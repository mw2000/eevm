defmodule EEVM do
  @moduledoc """
  EEVM — An Ethereum Virtual Machine implementation in Elixir.

  This is a learning project that implements the core EVM execution engine.
  It supports basic arithmetic, stack manipulation, memory operations,
  and control flow opcodes.

  ## Quick Start

      # Execute raw bytecode: PUSH1 2, PUSH1 3, ADD, STOP
      iex> result = EEVM.execute(<<0x60, 2, 0x60, 3, 0x01, 0x00>>)
      iex> result.status
      :stopped
      iex> EEVM.stack_values(result)
      [5]

  ## Architecture

  - `EEVM.Stack` — LIFO stack (max 1024, uint256 values)
  - `EEVM.Memory` — Byte-addressable linear memory
  - `EEVM.MachineState` — Combined execution state
  - `EEVM.Opcodes` — Opcode definitions and metadata
  - `EEVM.Executor` — The fetch-decode-execute loop

  ## Elixir Concepts Demonstrated

  - **Structs & Maps** — Data structures with compile-time field checks
  - **Pattern Matching** — Multi-clause functions, destructuring
  - **Tagged Tuples** — `{:ok, val}` / `{:error, reason}` error handling
  - **Recursion** — Tail-recursive execution loop (no mutable state)
  - **Bitwise Operations** — Working with 256-bit integers
  - **Module Attributes** — Compile-time constants
  - **Typespecs** — `@spec` annotations for documentation and Dialyzer
  """

  alias EEVM.{Executor, Stack}

  @doc """
  Executes EVM bytecode and returns the final machine state.

  ## Options
    - `:gas` — initial gas limit (default: 1,000,000)

  ## Example

      iex> result = EEVM.execute(<<0x60, 0x0A, 0x60, 0x14, 0x01, 0x00>>)
      iex> EEVM.stack_values(result)
      [30]
  """
  @spec execute(binary(), keyword()) :: EEVM.MachineState.t()
  def execute(bytecode, opts \\ []) do
    Executor.run(bytecode, opts)
  end

  @doc """
  Returns the stack contents as a list (top first).

  Convenience wrapper for inspecting results.
  """
  @spec stack_values(EEVM.MachineState.t()) :: [non_neg_integer()]
  def stack_values(state) do
    Stack.to_list(state.stack)
  end

  @doc """
  Disassembles bytecode into a human-readable list of instructions.

  ## Example

      iex> EEVM.disassemble(<<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>)
      [{0, "PUSH1", "0x01"}, {2, "PUSH1", "0x02"}, {4, "ADD", nil}, {5, "STOP", nil}]
  """
  @spec disassemble(binary()) :: [{non_neg_integer(), String.t(), String.t() | nil}]
  def disassemble(bytecode) do
    disassemble_loop(bytecode, 0, [])
  end

  defp disassemble_loop(bytecode, pc, acc) when pc < byte_size(bytecode) do
    opcode = :binary.at(bytecode, pc)

    case EEVM.Opcodes.info(opcode) do
      {:ok, %{push_bytes: n} = info} ->
        # PUSH instruction — read the immediate bytes
        data = binary_part(bytecode, min(pc + 1, byte_size(bytecode)), min(n, byte_size(bytecode) - pc - 1))
        hex = Base.encode16(data, case: :lower)
        disassemble_loop(bytecode, pc + 1 + n, [{pc, info.name, "0x" <> hex} | acc])

      {:ok, info} ->
        disassemble_loop(bytecode, pc + 1, [{pc, info.name, nil} | acc])

      {:error, _} ->
        disassemble_loop(bytecode, pc + 1, [{pc, "UNKNOWN(0x#{Integer.to_string(opcode, 16)})", nil} | acc])
    end
  end

  defp disassemble_loop(_bytecode, _pc, acc) do
    Enum.reverse(acc)
  end
end
