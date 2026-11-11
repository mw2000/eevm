defmodule EEVM.Interpreter.InstructionTable do
  @moduledoc """
  Per-hardfork instruction tables, built at compile time, and the programs
  decoded from them.

  A table is a 256-element tuple indexed by opcode byte. Each entry is an
  instruction `{opcode, static_gas, min_depth, max_depth, arg}`:

  - `opcode` — the opcode `EEVM.Interpreter` dispatches on
  - `static_gas` — the cost the interpreter charges before dispatch, from
    `EEVM.Gas.Static` for that hardfork
  - `min_depth` / `max_depth` — the stack depths the opcode can run at: it
    pops the Registry's `:inputs`, and must not leave more than 1024 items
  - `arg` — `nil` in the table; a decoded program puts PUSH data here

  Bytes the hardfork does not define — unassigned bytes, and opcodes whose
  activating EIP (the Registry's `:eip` field) is not yet enabled — get the
  INVALID (0xFE) entry, opcode included, so they halt exactly like INVALID
  even when their module implements them on later forks.

  `EEVM.Interpreter.MachineState.Env` resolves the table once per frame from
  the active hardfork, and `decode/3` turns a contract's code into a program
  of these instructions once per transaction, so the per-opcode path never
  checks which fork is active or decodes a byte.
  """

  import Bitwise, only: [<<<: 2]

  alias EEVM.Gas.Static
  alias EEVM.HardforkConfig
  alias EEVM.Interpreter.Instructions.Registry
  alias EEVM.Interpreter.Stack

  @type instruction ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), term()}
  @type t :: tuple()

  @typedoc """
  A decoded program: `elem(program, pc)` is the instruction at `pc`,
  `:push_data` inside PUSH data, and `:end` past the end of the code.
  """
  @type program :: tuple()

  @invalid 0xFE

  # A PUSH32 in the last code byte moves the pc 32 bytes past the end, so a
  # program ends with 33 `:end` entries rather than checking the pc's bound on
  # every opcode.
  @end_padding List.duplicate(:end, 33)

  @doc "Returns the instruction table for `spec_id`."
  @spec for_spec(HardforkConfig.spec_id()) :: t()
  def for_spec(spec_id)

  for spec_id <- HardforkConfig.all_spec_ids() do
    hardfork = HardforkConfig.new(spec_id)

    entry = fn opcode, info ->
      {opcode, Static.static_cost(opcode, spec_id), info.inputs,
       Stack.max_depth() - info.outputs + info.inputs, nil}
    end

    {:ok, invalid_info} = Registry.info(@invalid)
    invalid_entry = entry.(@invalid, invalid_info)

    table =
      for opcode <- 0x00..0xFF do
        case Registry.info(opcode) do
          {:ok, %{eip: eip} = info} ->
            if HardforkConfig.enabled?(hardfork, eip),
              do: entry.(opcode, info),
              else: invalid_entry

          {:ok, info} ->
            entry.(opcode, info)

          {:error, :unknown_opcode} ->
            invalid_entry
        end
      end

    def for_spec(unquote(spec_id)), do: unquote(Macro.escape(List.to_tuple(table)))
  end

  @doc """
  Decodes `code` into a program for `table`, with one entry per code byte.

  Opcodes are the table's own instructions, so most entries share them. A
  PUSH carries its value in `arg`, and its data bytes are `:push_data`, so a
  jump can land only on a real JUMPDEST (Yellow Paper §9.4.3). A PUSH cut
  short by the end of the code reads the missing bytes as zeros.

  With `tracing?`, each instruction is wrapped as `{:trace, byte, instruction}`: the
  interpreter records a trace step for the wrapper, then runs the
  instruction. Untraced programs carry no tracing cost at all.

      iex> alias EEVM.Interpreter.InstructionTable
      iex> table = InstructionTable.for_spec(:prague)
      iex> code = <<0x60, 0x03, 0x56, 0x5B>>
      iex> program = InstructionTable.decode(code, table, false)
      iex> elem(program, 0)
      {0x60, 3, 0, 1023, 3}
      iex> {elem(program, 1), elem(program, 4)}
      {:push_data, :end}
      iex> InstructionTable.decode(code, table, true) |> elem(0)
      {:trace, 0x60, {0x60, 3, 0, 1023, 3}}
  """
  @spec decode(binary(), t(), boolean()) :: program()
  def decode(code, table, tracing?) do
    # A traced program decodes from a traced table, so each byte costs the same.
    table =
      if tracing?,
        do: List.to_tuple(for(byte <- 0..255, do: {:trace, byte, elem(table, byte)})),
        else: table

    code
    |> decode(0, table, [])
    |> :lists.reverse(@end_padding)
    |> List.to_tuple()
  end

  defp decode(<<byte, rest::binary>>, pc, table, acc) when byte in 0x60..0x7F do
    n = byte - 0x5F

    case rest do
      <<value::size(n)-unit(8), rest::binary>> ->
        push = table |> elem(byte) |> with_value(value)
        decode(rest, pc + n + 1, table, push_data([push | acc], n))

      _truncated ->
        value = :binary.decode_unsigned(rest) <<< (8 * (n - byte_size(rest)))
        push_data([with_value(elem(table, byte), value) | acc], byte_size(rest))
    end
  end

  defp decode(<<byte, rest::binary>>, pc, table, acc),
    do: decode(rest, pc + 1, table, [elem(table, byte) | acc])

  defp decode(<<>>, _pc, _table, acc), do: acc

  defp with_value({:trace, byte, push}, value), do: {:trace, byte, with_value(push, value)}
  defp with_value(push, value), do: put_elem(push, 4, value)

  defp push_data(acc, 0), do: acc
  defp push_data(acc, n), do: push_data([:push_data | acc], n - 1)
end
