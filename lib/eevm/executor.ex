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

  alias EEVM.{MachineState, Stack, Memory, Storage, Block, Contract, Opcodes, Gas}

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
        static_cost = if opcode == 0xFE, do: state.gas, else: Gas.static_cost(opcode)

        case MachineState.consume_gas(state, static_cost) do
          {:ok, state_after_gas} ->
            case execute_opcode(opcode, state_after_gas) do
              {:ok, new_state} -> run_loop(new_state)
              {:error, :out_of_gas, halted_state} -> halted_state
              {:error, reason, error_state} -> MachineState.halt(error_state, {:error, reason})
            end

          {:error, :out_of_gas, halted_state} ->
            halted_state
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
         {:ok, b, s2} <- Stack.pop(s1),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s2}, Gas.exp_dynamic_cost(b)) do
      result = mod_pow(a, b, @max_uint256 + 1)
      {:ok, s3} = Stack.push(state_after_gas.stack, result)
      {:ok, %{state_after_gas | stack: s3} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
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

  # KECCAK256 (0x20): compute Keccak-256 hash of memory region
  #
  # Pops offset and length from stack, reads `length` bytes from memory,
  # hashes them with Keccak-256, and pushes the 256-bit hash.
  #
  # Gas: 30 (static) + 6 per 32-byte word (dynamic) + memory expansion.
  #
  # Elixir Learning Note: Ethereum uses Keccak-256, NOT SHA3-256 (NIST
  # standardized a different padding). We use the `ex_keccak` library
  # which provides a NIF binding. The result is a 32-byte binary.
  defp execute_opcode(0x20, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, length, s2} <- Stack.pop(s1) do
      # Charge dynamic gas: 6 per 32-byte word (rounded up)
      _word_count = div(length + 31, 32)
      dynamic_cost = Gas.keccak256_dynamic_cost(length)

      # Charge memory expansion gas
      mem_cost =
        if length > 0 do
          Gas.memory_expansion_cost(Memory.size(state.memory), offset, length)
        else
          0
        end

      case MachineState.consume_gas(state, dynamic_cost + mem_cost) do
        {:ok, state_after_gas} ->
          # Read bytes from memory
          {data, updated_memory} =
            if length > 0 do
              Memory.read_bytes(state_after_gas.memory, offset, length)
            else
              {<<>>, state_after_gas.memory}
            end

          hash = ExKeccak.hash_256(data)
          <<hash_int::unsigned-big-256>> = hash
          {:ok, new_stack} = Stack.push(s2, hash_int)

          {:ok,
           %{state_after_gas | stack: new_stack, memory: updated_memory}
           |> MachineState.advance_pc()}

        {:error, :out_of_gas, halted} ->
          {:error, :out_of_gas, halted}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # PUSH0 (0x5F): push zero onto the stack — EIP-3855
  #
  # The simplest opcode added in the Shanghai upgrade. Saves gas vs
  # PUSH1 0x00 (costs 2 instead of 3). Modern Solidity compilers emit
  # this whenever they need a zero value on the stack.
  defp execute_opcode(0x5F, state) do
    {:ok, new_stack} = Stack.push(state.stack, 0)
    {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}
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
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         expansion_cost =
           Gas.memory_expansion_cost_word(Memory.size(state.memory), offset),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s1}, expansion_cost) do
      {value, new_memory} = Memory.load(state_after_gas.memory, offset)
      {:ok, s2} = Stack.push(state_after_gas.stack, value)
      {:ok, %{state_after_gas | stack: s2, memory: new_memory} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  # MSTORE (0x52): store word to memory
  defp execute_opcode(0x52, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1),
         expansion_cost =
           Gas.memory_expansion_cost_word(Memory.size(state.memory), offset),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s2}, expansion_cost) do
      new_memory = Memory.store(state_after_gas.memory, offset, value)
      {:ok, %{state_after_gas | stack: s2, memory: new_memory} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  # MSTORE8 (0x53): store byte to memory
  defp execute_opcode(0x53, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1),
         expansion_cost =
           Gas.memory_expansion_cost_byte(Memory.size(state.memory), offset),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s2}, expansion_cost) do
      new_memory = Memory.store_byte(state_after_gas.memory, offset, value)
      {:ok, %{state_after_gas | stack: s2, memory: new_memory} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  # SLOAD (0x54): load from storage
  #
  # Pops a key from the stack, looks it up in storage, and pushes the value.
  # Uninitialized slots return 0.
  #
  # ## Elixir Learning Note
  #
  # `Storage.load/2` uses `Map.get/3` with a default of 0, so we never
  # need to check if the key exists — missing keys just return 0.
  defp execute_opcode(0x54, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack),
         value = Storage.load(state.storage, key),
         {:ok, s2} <- Stack.push(s1, value) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # SSTORE (0x55): store to storage
  #
  # Pops a key and value from the stack, writes the value to storage.
  # This is the most expensive common opcode (20,000 gas) because it
  # modifies persistent blockchain state.
  #
  # ## Elixir Learning Note
  #
  # `Storage.store/3` returns a *new* storage struct — it doesn't mutate
  # the old one. This is functional programming: every "write" creates a
  # new version of the data structure.
  defp execute_opcode(0x55, state) do
    with {:ok, key, s1} <- Stack.pop(state.stack),
         {:ok, value, s2} <- Stack.pop(s1) do
      new_storage = Storage.store(state.storage, key, value)
      {:ok, %{state | stack: s2, storage: new_storage} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # ── Environment Opcodes ──────────────────────────────────────────────
  #
  # These opcodes read from the separated context modules (Transaction, Block, Contract) —
  # the current call, transaction, and block. They don't modify state,
  # just push values onto the stack.
  #
  # ## Elixir Learning Note
  #
  # These are all trivially simple: read a field, push it. The pattern
  # `state.tx.*`, `state.block.*`, and `state.contract.*` fields. In Elixir, this is
  # syntactic sugar for `Map.get(Map.get(state, :context), :field)`.

  # ADDRESS (0x30): push the executing contract's address
  defp execute_opcode(0x30, state) do
    push_value(state, state.contract.address)
  end

  # BALANCE (0x31): pop address, push its balance
  defp execute_opcode(0x31, state) do
    with {:ok, addr, s1} <- Stack.pop(state.stack),
         balance = Contract.balance(state.contract, addr),
         {:ok, s2} <- Stack.push(s1, balance) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # ORIGIN (0x32): push the transaction sender (EOA, not the direct caller)
  defp execute_opcode(0x32, state) do
    push_value(state, state.tx.origin)
  end

  # CALLER (0x33): push the direct caller of this call frame
  defp execute_opcode(0x33, state) do
    push_value(state, state.contract.caller)
  end

  # CALLVALUE (0x34): push the ETH (in wei) sent with this call
  defp execute_opcode(0x34, state) do
    push_value(state, state.contract.callvalue)
  end

  # CALLDATALOAD (0x35): pop offset, push 32 bytes of calldata
  defp execute_opcode(0x35, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         value = Contract.calldata_load(state.contract, offset),
         {:ok, s2} <- Stack.push(s1, value) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # CALLDATASIZE (0x36): push the byte length of calldata
  defp execute_opcode(0x36, state) do
    push_value(state, byte_size(state.contract.calldata))
  end

  # CALLDATACOPY (0x37): copy calldata to memory
  #
  # Pops: dest_offset, data_offset, length
  # Copies `length` bytes from calldata starting at `data_offset`
  # into memory starting at `dest_offset`.
  defp execute_opcode(0x37, state) do
    with {:ok, dest_offset, s1} <- Stack.pop(state.stack),
         {:ok, data_offset, s2} <- Stack.pop(s1),
         {:ok, length, s3} <- Stack.pop(s2) do
      if length == 0 do
        {:ok, %{state | stack: s3} |> MachineState.advance_pc()}
      else
        # Charge memory expansion gas
        expansion_cost = Gas.memory_expansion_cost(Memory.size(state.memory), dest_offset, length)

        case MachineState.consume_gas(%{state | stack: s3}, expansion_cost) do
          {:ok, state_after_gas} ->
            calldata = state_after_gas.contract.calldata
            cd_size = byte_size(calldata)

            # Extract bytes from calldata, zero-padding beyond its end
            bytes =
              for i <- 0..(length - 1), into: <<>> do
                if data_offset + i < cd_size do
                  <<:binary.at(calldata, data_offset + i)>>
                else
                  <<0>>
                end
              end

            # Write bytes to memory one at a time
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

  # CODESIZE (0x38): push the byte length of the executing code
  defp execute_opcode(0x38, state) do
    push_value(state, byte_size(state.code))
  end

  # GASPRICE (0x3A): push the gas price of the transaction
  defp execute_opcode(0x3A, state) do
    push_value(state, state.tx.gasprice)
  end

  # RETURNDATASIZE (0x3D): push the size of the last RETURN/REVERT data
  defp execute_opcode(0x3D, state) do
    push_value(state, byte_size(state.return_data))
  end

  # BLOCKHASH (0x40): pop block number, push its hash
  defp execute_opcode(0x40, state) do
    with {:ok, block_num, s1} <- Stack.pop(state.stack),
         hash = Block.hash(state.block, block_num),
         {:ok, s2} <- Stack.push(s1, hash) do
      {:ok, %{state | stack: s2} |> MachineState.advance_pc()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # COINBASE (0x41): push the block producer's address
  defp execute_opcode(0x41, state) do
    push_value(state, state.block.coinbase)
  end

  # TIMESTAMP (0x42): push the block timestamp
  defp execute_opcode(0x42, state) do
    push_value(state, state.block.timestamp)
  end

  # NUMBER (0x43): push the block number
  defp execute_opcode(0x43, state) do
    push_value(state, state.block.number)
  end

  # PREVRANDAO (0x44): push the previous block's RANDAO mix
  defp execute_opcode(0x44, state) do
    push_value(state, state.block.prevrandao)
  end

  # GASLIMIT (0x45): push the block gas limit
  defp execute_opcode(0x45, state) do
    push_value(state, state.block.gaslimit)
  end

  # CHAINID (0x46): push the chain ID (1 = mainnet)
  defp execute_opcode(0x46, state) do
    push_value(state, state.block.chain_id)
  end

  # SELFBALANCE (0x47): push the balance of the executing contract
  defp execute_opcode(0x47, state) do
    balance = Contract.balance(state.contract, state.contract.address)
    push_value(state, balance)
  end

  # BASEFEE (0x48): push the block's base fee (EIP-1559)
  defp execute_opcode(0x48, state) do
    push_value(state, state.block.basefee)
  end

  # GAS (0x5A): push remaining gas (after this opcode's cost)
  defp execute_opcode(0x5A, state) do
    push_value(state, state.gas)
  end

  # ── End Environment Opcodes ──────────────────────────────────────────

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
         {:ok, length, s2} <- Stack.pop(s1),
         expansion_cost =
           Gas.memory_expansion_cost(Memory.size(state.memory), offset, length),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s2}, expansion_cost) do
      {return_data, new_memory} = Memory.read_bytes(state_after_gas.memory, offset, length)

      {:ok,
       %{state_after_gas | stack: s2, memory: new_memory, return_data: return_data}
       |> MachineState.halt(:stopped)}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
    end
  end

  # REVERT (0xFD): halt, revert, and return data
  defp execute_opcode(0xFD, state) do
    with {:ok, offset, s1} <- Stack.pop(state.stack),
         {:ok, length, s2} <- Stack.pop(s1),
         expansion_cost =
           Gas.memory_expansion_cost(Memory.size(state.memory), offset, length),
         {:ok, state_after_gas} <-
           MachineState.consume_gas(%{state | stack: s2}, expansion_cost) do
      {return_data, new_memory} = Memory.read_bytes(state_after_gas.memory, offset, length)

      {:ok,
       %{state_after_gas | stack: s2, memory: new_memory, return_data: return_data}
       |> MachineState.halt(:reverted)}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, :out_of_gas, halted_state} -> {:error, :out_of_gas, halted_state}
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

  # Helper for environment opcodes that just push a single value.
  # Reduces boilerplate — most env ops are: read field, push, advance PC.
  defp push_value(state, value) do
    {:ok, new_stack} = Stack.push(state.stack, value)
    {:ok, %{state | stack: new_stack} |> MachineState.advance_pc()}
  end

  # Checks if a position in the code is a valid JUMPDEST
  defp valid_jumpdest?(code, dest) when dest < byte_size(code) do
    :binary.at(code, dest) == 0x5B
  end

  defp valid_jumpdest?(_code, _dest), do: false
end
