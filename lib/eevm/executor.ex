defmodule EEVM.Executor do
  @moduledoc """
  The EVM execution engine — implements the fetch-decode-execute cycle.

  ## EVM Concepts

  The executor repeatedly:
  1. **Fetches** the opcode at the current program counter
  2. **Decodes** it to determine what operation to perform
  3. **Executes** the operation, modifying the machine state
  4. **Advances** the program counter

  Execution continues until a STOP, RETURN, REVERT, or INVALID is hit,
  or the program counter runs past the end of the bytecode.

  ## Elixir Learning Notes

  - Recursion replaces loops in Elixir. The `run_loop/1` function calls
    itself with updated state — this is tail-recursive and optimized by
    the BEAM VM (Erlang's virtual machine).
  - `with` expressions chain pattern-matched operations — if any step
    fails, the non-matching clause falls through to `else`.
  - Multi-clause functions with pattern matching act like a switch/case
    but are more powerful — they can destructure arguments.
  - `import Bitwise` gives us operators like `band`, `bor`, `bxor`, `bnot`.
  """

  alias EEVM.{MachineState, Stack, Memory, Opcodes}

  import Bitwise

  @max_uint256 (1 <<< 256) - 1
  @sign_bit 1 <<< 255

  @doc """
  Executes EVM bytecode and returns the final machine state.

  ## Example

      iex> # PUSH1 0x02, PUSH1 0x03, ADD, STOP
      iex> code = <<0x60, 0x02, 0x60, 0x03, 0x01, 0x00>>
      iex> state = EEVM.Executor.run(code)
      iex> state.status
      :stopped
      iex> EEVM.Stack.to_list(state.stack)
      [5]
  """
  @spec run(binary(), keyword()) :: MachineState.t()
  def run(code, opts \\ []) do
    code
    |> MachineState.new(opts)
    |> run_loop()
  end

  @doc "Resumes execution from an existing machine state."
  @spec run_loop(MachineState.t()) :: MachineState.t()
  def run_loop(%MachineState{status: :running} = state) do
    case MachineState.current_opcode(state) do
      nil ->
        # Ran past end of code — implicit STOP
        MachineState.halt(state, :stopped)

      opcode ->
        case execute_opcode(opcode, state) do
          {:ok, new_state} -> run_loop(new_state)
          {:error, reason, state} -> MachineState.halt(state, {:error, reason})
        end
    end
  end

  # If the machine is not running, return it as-is
  def run_loop(state), do: state

  # --- Opcode Implementations ---

  # STOP (0x00): Halts execution
  defp execute_opcode(0x00, state) do
    {:ok, MachineState.halt(state, :stopped)}
  end

  # ADD (0x01): a + b (mod 2^256)
  defp execute_opcode(0x01, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1),
         result = band(a + b, @max_uint256),
         {:ok, s3} <- Stack.push(s2, result) do
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # MUL (0x02): a * b (mod 2^256)
  defp execute_opcode(0x02, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1),
         result = band(a * b, @max_uint256),
         {:ok, s3} <- Stack.push(s2, result) do
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SUB (0x03): a - b (mod 2^256)
  defp execute_opcode(0x03, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1),
         result = band(a - b, @max_uint256),
         {:ok, s3} <- Stack.push(s2, result) do
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # DIV (0x04): a / b (integer division, 0 if b == 0)
  defp execute_opcode(0x04, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = if b == 0, do: 0, else: div(a, b)
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SDIV (0x05): signed division
  defp execute_opcode(0x05, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result =
        if b == 0 do
          0
        else
          sa = to_signed(a)
          sb = to_signed(b)
          to_unsigned(div(sa, sb))
        end

      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # MOD (0x06): a mod b (0 if b == 0)
  defp execute_opcode(0x06, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = if b == 0, do: 0, else: rem(a, b)
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SMOD (0x07): signed modulo
  defp execute_opcode(0x07, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result =
        if b == 0 do
          0
        else
          sa = to_signed(a)
          sb = to_signed(b)
          to_unsigned(rem(sa, sb))
        end

      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # ADDMOD (0x08): (a + b) mod N
  defp execute_opcode(0x08, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1),
         {:ok, n, s3} <- Stack.pop(s2) do
      result = if n == 0, do: 0, else: rem(a + b, n)
      {:ok, s4} = Stack.push(s3, result)
      {:ok, %{state | stack: s4} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # MULMOD (0x09): (a * b) mod N
  defp execute_opcode(0x09, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1),
         {:ok, n, s3} <- Stack.pop(s2) do
      result = if n == 0, do: 0, else: rem(a * b, n)
      {:ok, s4} = Stack.push(s3, result)
      {:ok, %{state | stack: s4} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # EXP (0x0A): a ** b (mod 2^256)
  defp execute_opcode(0x0A, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = mod_pow(a, b, @max_uint256 + 1)
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SIGNEXTEND (0x0B): sign-extend the (b)th byte of a
  defp execute_opcode(0x0B, state) do
    with {:ok, b, s1} <- Stack.pop(state.stack),
         {:ok, x, s2} <- Stack.pop(s1) do
      result =
        if b < 31 do
          bit = b * 8 + 7
          mask = (1 <<< bit) - 1

          if (x >>> bit &&& 1) == 1 do
            band(x ||| Bitwise.bnot(mask), @max_uint256)
          else
            band(x, mask)
          end
        else
          x
        end

      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # LT (0x10): a < b
  defp execute_opcode(0x10, state), do: comparison_op(state, &Kernel.</2)

  # GT (0x11): a > b
  defp execute_opcode(0x11, state), do: comparison_op(state, &Kernel.>/2)

  # SLT (0x12): signed a < signed b
  defp execute_opcode(0x12, state) do
    signed_comparison_op(state, &Kernel.</2)
  end

  # SGT (0x13): signed a > signed b
  defp execute_opcode(0x13, state) do
    signed_comparison_op(state, &Kernel.>/2)
  end

  # EQ (0x14): a == b
  defp execute_opcode(0x14, state), do: comparison_op(state, &Kernel.==/2)

  # ISZERO (0x15): a == 0
  defp execute_opcode(0x15, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack) do
      result = if a == 0, do: 1, else: 0
      {:ok, s2} = Stack.push(s1, result)
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # AND (0x16): bitwise and
  defp execute_opcode(0x16, state), do: bitwise_op(state, &band/2)

  # OR (0x17): bitwise or
  defp execute_opcode(0x17, state), do: bitwise_op(state, &bor/2)

  # XOR (0x18): bitwise xor
  defp execute_opcode(0x18, state), do: bitwise_op(state, &bxor/2)

  # NOT (0x19): bitwise not
  defp execute_opcode(0x19, state) do
    with {:ok, a, s1} <- Stack.pop(state.stack) do
      result = band(Bitwise.bnot(a), @max_uint256)
      {:ok, s2} = Stack.push(s1, result)
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # BYTE (0x1A): ith byte of x (0 = most significant)
  defp execute_opcode(0x1A, state) do
    with {:ok, i, s1} <- Stack.pop(state.stack),
         {:ok, x, s2} <- Stack.pop(s1) do
      result =
        if i < 32 do
          # Byte 0 is the most significant byte
          shift = (31 - i) * 8
          band(x >>> shift, 0xFF)
        else
          0
        end

      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SHL (0x1B): shift left
  defp execute_opcode(0x1B, state) do
    with {:ok, shift, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      result = if shift >= 256, do: 0, else: band(value <<< shift, @max_uint256)
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SHR (0x1C): logical shift right
  defp execute_opcode(0x1C, state) do
    with {:ok, shift, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      result = if shift >= 256, do: 0, else: value >>> shift
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SAR (0x1D): arithmetic shift right (preserves sign)
  defp execute_opcode(0x1D, state) do
    with {:ok, shift, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      signed = to_signed(value)

      result =
        cond do
          shift >= 256 and signed < 0 -> @max_uint256
          shift >= 256 -> 0
          true -> to_unsigned(signed >>> shift)
        end

      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # POP (0x50): discard top of stack
  defp execute_opcode(0x50, state) do
    case Stack.pop(state.stack) do
      {:ok, _value, new_stack} ->
        {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # MLOAD (0x51): load word from memory
  defp execute_opcode(0x51, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack) do
      {value, new_memory} = Memory.load(state.memory, offset)
      {:ok, s2} = Stack.push(s1, value)
      {:ok, %{state | stack: s2, memory: new_memory} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # MSTORE (0x52): store word to memory
  defp execute_opcode(0x52, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      new_memory = Memory.store(state.memory, offset, value)
      {:ok, %{state | stack: s2, memory: new_memory} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # MSTORE8 (0x53): store byte to memory
  defp execute_opcode(0x53, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      new_memory = Memory.store_byte(state.memory, offset, value)
      {:ok, %{state | stack: s2, memory: new_memory} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # MSIZE (0x59): get memory size
  defp execute_opcode(0x59, state) do
    size = Memory.size(state.memory)

    case Stack.push(state.stack, size) do
      {:ok, new_stack} ->
        {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # JUMP (0x56): unconditional jump
  defp execute_opcode(0x56, state) do
    with {:ok, dest, s1} <- Stack.pop(state.stack) do
      if valid_jumpdest?(state.code, dest) do
        {:ok, %{state | stack: s1, pc: dest}}
      else
        {:error, :invalid_jump_destination, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # JUMPI (0x57): conditional jump
  defp execute_opcode(0x57, state) do
    with {:ok, dest, s1} <- Stack.pop(state.stack),
         {:ok, condition, s2} <- Stack.pop(s1) do
      if condition != 0 do
        if valid_jumpdest?(state.code, dest) do
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

  # PC (0x58): get program counter
  defp execute_opcode(0x58, state) do
    case Stack.push(state.stack, state.pc) do
      {:ok, new_stack} ->
        {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # JUMPDEST (0x5B): marks a valid jump destination (no-op)
  defp execute_opcode(0x5B, state) do
    {:ok, MachineState.advance_pc(state)}
  end

  # PUSH1–PUSH32 (0x60–0x7F)
  defp execute_opcode(op, state) when op >= 0x60 and op <= 0x7F do
    n = Opcodes.push_bytes(op)
    bytes = MachineState.read_code(state, state.pc + 1, n)

    # Convert the N bytes to an integer (big-endian)
    value =
      bytes
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, acc -> acc * 256 + byte end)

    case Stack.push(state.stack, value) do
      {:ok, new_stack} ->
        # Advance PC past the opcode AND the N immediate bytes
        {:ok, %{state | stack: new_stack} |> MachineState.advance_pc(1 + n)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # DUP1–DUP16 (0x80–0x8F)
  defp execute_opcode(op, state) when op >= 0x80 and op <= 0x8F do
    depth = op - 0x80

    with {:ok, value} <- Stack.peek(state.stack, depth),
         {:ok, new_stack} <- Stack.push(state.stack, value) do
      {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SWAP1–SWAP16 (0x90–0x9F)
  defp execute_opcode(op, state) when op >= 0x90 and op <= 0x9F do
    depth = op - 0x90 + 1

    case Stack.swap(state.stack, depth) do
      {:ok, new_stack} ->
        {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # RETURN (0xF3): halt and return data
  defp execute_opcode(0xF3, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, length, s2} <- Stack.pop(s1) do
      {return_data, new_memory} = Memory.read_bytes(state.memory, offset, length)

      {:ok,
       %{state | stack: s2, memory: new_memory, return_data: return_data}
       |> MachineState.halt(:stopped)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # REVERT (0xFD): halt, revert, and return data
  defp execute_opcode(0xFD, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, length, s2} <- Stack.pop(s1) do
      {return_data, new_memory} = Memory.read_bytes(state.memory, offset, length)

      {:ok,
       %{state | stack: s2, memory: new_memory, return_data: return_data}
       |> MachineState.halt(:reverted)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # INVALID (0xFE): explicit invalid instruction
  defp execute_opcode(0xFE, state) do
    {:ok, MachineState.halt(state, :invalid)}
  end

  # Unknown opcode — invalid
  defp execute_opcode(_unknown, state) do
    {:ok, MachineState.halt(state, :invalid)}
  end

  # --- Helpers ---

  # Helper for binary comparison operations (LT, GT, EQ)
  defp comparison_op(state, fun) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = if fun.(a, b), do: 1, else: 0
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Helper for signed comparison operations (SLT, SGT)
  defp signed_comparison_op(state, fun) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = if fun.(to_signed(a), to_signed(b)), do: 1, else: 0
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Helper for binary bitwise operations (AND, OR, XOR)
  defp bitwise_op(state, fun) do
    with {:ok, a, s1} <- Stack.pop(state.stack),
         {:ok, b, s2} <- Stack.pop(s1) do
      result = fun.(a, b)
      {:ok, s3} = Stack.push(s2, result)
      {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Converts a uint256 to a signed integer (two's complement)
  defp to_signed(value) when value >= @sign_bit, do: value - (@max_uint256 + 1)
  defp to_signed(value), do: value

  # Converts a signed integer back to uint256
  defp to_unsigned(value) when value < 0, do: value + @max_uint256 + 1
  defp to_unsigned(value), do: value

  # Modular exponentiation: base^exp mod m
  # Uses the square-and-multiply algorithm for efficiency.
  defp mod_pow(_base, 0, _m), do: 1
  defp mod_pow(base, 1, m), do: rem(base, m)

  defp mod_pow(base, exp, m) do
    half = mod_pow(base, div(exp, 2), m)
    half_sq = rem(half * half, m)

    if rem(exp, 2) == 0 do
      half_sq
    else
      rem(half_sq * rem(base, m), m)
    end
  end

  # Checks if a position in the code is a valid JUMPDEST
  defp valid_jumpdest?(code, dest) when dest < byte_size(code) do
    :binary.at(code, dest) == 0x5B
  end

  defp valid_jumpdest?(_code, _dest), do: false
end
