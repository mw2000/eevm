defmodule EEVM.Interpreter.Instructions.ExhaustivenessTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Ensures every known opcode produces a valid result when executed.

  Inspired by revm's exhaustiveness test — this verifies that no opcode byte
  silently falls through to an undefined handler. Every opcode in the registry
  should either execute successfully or halt with a recognized status (not crash).
  """

  # Collect every opcode that the registry recognizes
  @all_known_opcodes (for byte <- 0x00..0xFF,
                          {:ok, _info} <- [EEVM.Interpreter.Instructions.Registry.info(byte)] do
                        byte
                      end)

  describe "opcode exhaustiveness" do
    test "every known opcode executes without crashing" do
      for opcode <- @all_known_opcodes do
        # Build minimal bytecode: just the opcode followed by STOP
        # For PUSH opcodes, pad with enough zero bytes
        bytecode = build_bytecode(opcode)

        result = EEVM.execute(bytecode, gas: 1_000_000)

        assert result.status in [
                 :stopped,
                 :reverted,
                 :invalid,
                 :out_of_gas,
                 {:error, :stack_underflow},
                 {:error, :stack_overflow},
                 {:error, :invalid_jump},
                 {:error, :invalid_staticcall}
               ],
               "Opcode 0x#{Integer.to_string(opcode, 16)} produced unexpected status: #{inspect(result.status)}"
      end
    end

    test "all standard opcodes are in the registry" do
      # These are the opcode ranges that MUST be handled
      standard_opcodes =
        [0x00] ++
          Enum.to_list(0x01..0x0B) ++
          Enum.to_list(0x10..0x15) ++
          Enum.to_list(0x16..0x1D) ++
          [0x20] ++
          Enum.to_list(0x30..0x3F) ++
          Enum.to_list(0x40..0x4A) ++
          Enum.to_list(0x50..0x5F) ++
          Enum.to_list(0x60..0x9F) ++
          Enum.to_list(0xA0..0xA4) ++
          [0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xFA, 0xFD, 0xFE, 0xFF]

      for opcode <- standard_opcodes do
        assert {:ok, info} = EEVM.Interpreter.Instructions.Registry.info(opcode),
               "Opcode 0x#{Integer.to_string(opcode, 16)} is missing from the registry"

        assert is_binary(info.name),
               "Opcode 0x#{Integer.to_string(opcode, 16)} has no name in registry"
      end
    end

    test "unknown opcodes halt as invalid" do
      # Pick some unassigned opcodes
      unassigned = [0x0C, 0x0D, 0x0E, 0x0F, 0x1E, 0x1F, 0x21, 0x4B, 0xA5, 0xB0, 0xEF]

      for opcode <- unassigned do
        bytecode = <<opcode, 0x00>>
        result = EEVM.execute(bytecode, gas: 1_000_000)

        assert result.status == :invalid,
               "Unassigned opcode 0x#{Integer.to_string(opcode, 16)} should halt as :invalid, got: #{inspect(result.status)}"
      end
    end
  end

  defp build_bytecode(opcode) do
    case EEVM.Interpreter.Instructions.Registry.info(opcode) do
      {:ok, %{push_bytes: n}} ->
        # PUSH instructions need n bytes of data after them
        padding = :binary.copy(<<0>>, n)
        <<opcode, padding::binary, 0x00>>

      {:ok, _info} ->
        <<opcode, 0x00>>

      _ ->
        <<opcode, 0x00>>
    end
  end
end
