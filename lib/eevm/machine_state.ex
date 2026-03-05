defmodule EEVM.MachineState do
  @moduledoc """
  The EVM machine state — holds all mutable state during execution.

  ## EVM Concepts

  The machine state consists of:
  - **pc** (program counter): points to the current instruction
  - **stack**: the operand stack (max 1024 elements)
  - **memory**: byte-addressable linear memory
  - **gas**: remaining gas for execution
  - **status**: whether the machine is running, stopped, or reverted

  ## Elixir Learning Notes

  - Structs in Elixir are just maps with a `__struct__` key. They give you
    compile-time guarantees about which fields exist.
  - `@enforce_keys` makes certain fields required when creating a struct.
  - We use atoms like `:running`, `:stopped`, `:reverted` for status —
    atoms are constants whose name IS their value (like symbols in Ruby).
  - The `alias` keyword lets us reference modules by their short name.
  """

  alias EEVM.{Stack, Memory}

  @type status :: :running | :stopped | :reverted | :invalid

  @type t :: %__MODULE__{
          pc: non_neg_integer(),
          stack: Stack.t(),
          memory: Memory.t(),
          gas: non_neg_integer(),
          status: status(),
          return_data: binary(),
          code: binary()
        }

  @enforce_keys [:code]
  defstruct pc: 0,
            stack: nil,
            memory: nil,
            gas: 1_000_000,
            status: :running,
            return_data: <<>>,
            code: <<>>

  @doc """
  Creates a new machine state for executing the given bytecode.

  ## Parameters
    - `code` — the raw EVM bytecode as an Elixir binary
    - `opts` — optional keyword list:
      - `:gas` — initial gas (default: 1,000,000)

  ## Example

      iex> state = EEVM.MachineState.new(<<0x60, 0x01, 0x60, 0x02, 0x01>>)
      iex> state.pc
      0
  """
  @spec new(binary(), keyword()) :: t()
  def new(code, opts \\ []) do
    %__MODULE__{
      code: code,
      stack: Stack.new(),
      memory: Memory.new(),
      gas: Keyword.get(opts, :gas, 1_000_000)
    }
  end

  @doc "Returns the opcode byte at the current program counter, or nil if past end."
  @spec current_opcode(t()) :: non_neg_integer() | nil
  def current_opcode(%__MODULE__{pc: pc, code: code}) when pc < byte_size(code) do
    :binary.at(code, pc)
  end

  def current_opcode(_state), do: nil

  @doc """
  Reads `n` bytes from the code starting at `offset`.

  Used by PUSH instructions to read their immediate data.
  """
  @spec read_code(t(), non_neg_integer(), non_neg_integer()) :: binary()
  def read_code(%__MODULE__{code: code}, offset, n) do
    code_size = byte_size(code)

    if offset >= code_size do
      # Past end of code — return zeros (EVM spec: treat as 0x00)
      <<0::size(n * 8)>>
    else
      available = min(n, code_size - offset)
      chunk = binary_part(code, offset, available)
      # Pad with zeros if we read past the end
      padding_size = (n - available) * 8
      <<chunk::binary, 0::size(padding_size)>>
    end
  end

  @doc "Advances the program counter by `n` positions."
  @spec advance_pc(t(), non_neg_integer()) :: t()
  def advance_pc(state, n \\ 1) do
    %{state | pc: state.pc + n}
  end

  @doc "Halts execution with the given status."
  @spec halt(t(), status()) :: t()
  def halt(state, status) do
    %{state | status: status}
  end
end
