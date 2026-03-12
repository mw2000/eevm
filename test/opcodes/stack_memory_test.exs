defmodule EEVM.Opcodes.StackMemoryTest do
  use ExUnit.Case, async: true

  alias EEVM.Gas.{Dynamic, Memory, Static}

  describe "Executor - Memory" do
    test "MSTORE and MLOAD" do
      # PUSH1 0xFF, PUSH1 0, MSTORE, PUSH1 0, MLOAD, STOP
      code = <<0x60, 0xFF, 0x60, 0, 0x52, 0x60, 0, 0x51, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [0xFF]
    end

    test "MSIZE" do
      # PUSH1 1, PUSH1 0, MSTORE, MSIZE, STOP
      code = <<0x60, 1, 0x60, 0, 0x52, 0x59, 0x00>>
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [32]
    end
  end

  # ── MCOPY Tests (EIP-5656) ──────
  describe "MCOPY (EIP-5656)" do
    test "non-overlapping copy" do
      code =
        IO.iodata_to_binary([
          mstore8(0, 0xAA),
          mstore8(1, 0xBB),
          mstore8(2, 0xCC),
          mstore8(3, 0xDD),
          mcopy(32, 0, 4),
          mload(32),
          <<0x00>>
        ])

      result = EEVM.execute(code)
      [word] = EEVM.stack_values(result)

      assert bytes32(word) |> Enum.take(4) == [0xAA, 0xBB, 0xCC, 0xDD]
    end

    test "overlapping forward copy uses memmove semantics" do
      code =
        IO.iodata_to_binary([
          mstore8(0, 0x11),
          mstore8(1, 0x22),
          mstore8(2, 0x33),
          mstore8(3, 0x44),
          mcopy(1, 0, 3),
          mload(0),
          <<0x00>>
        ])

      result = EEVM.execute(code)
      [word] = EEVM.stack_values(result)

      assert bytes32(word) |> Enum.take(4) == [0x11, 0x11, 0x22, 0x33]
    end

    test "overlapping backward copy uses memmove semantics" do
      code =
        IO.iodata_to_binary([
          mstore8(0, 0x11),
          mstore8(1, 0x22),
          mstore8(2, 0x33),
          mstore8(3, 0x44),
          mcopy(0, 1, 3),
          mload(0),
          <<0x00>>
        ])

      result = EEVM.execute(code)
      [word] = EEVM.stack_values(result)

      assert bytes32(word) |> Enum.take(4) == [0x22, 0x33, 0x44, 0x44]
    end

    test "zero-length copy is a no-op and keeps msize unchanged" do
      code =
        IO.iodata_to_binary([
          mstore8(0, 0xAA),
          <<0x59>>,
          mcopy(0, 0, 0),
          <<0x59, 0x00>>
        ])

      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [32, 32]
    end

    test "gas calculation includes static, copy words, and memory expansion" do
      code = IO.iodata_to_binary([mcopy(64, 0, 33), <<0x00>>])
      result = EEVM.execute(code, gas: 100_000)

      expected =
        3 + 3 + 3 + Static.static_cost(0x5E) + Dynamic.copy_cost(33) +
          Memory.memory_expansion_cost(0, 0, 97)

      assert result.status == :stopped
      assert result.gas == 100_000 - expected
    end

    test "memory expansion covers both src and dst ranges" do
      code = IO.iodata_to_binary([mcopy(0, 96, 32), <<0x59, 0x00>>])
      result = EEVM.execute(code)
      assert EEVM.stack_values(result) == [128]
    end

    test "large copy across word boundaries" do
      writes =
        for i <- 0..39 do
          mstore8(i, i + 1)
        end

      code =
        IO.iodata_to_binary([
          writes,
          mcopy(64, 0, 40),
          mload(96),
          mload(64),
          <<0x00>>
        ])

      result = EEVM.execute(code)
      [word1, word2] = EEVM.stack_values(result)

      assert bytes32(word1) == Enum.to_list(1..32)
      assert bytes32(word2) |> Enum.take(8) == Enum.to_list(33..40)
      assert bytes32(word2) |> Enum.drop(8) == List.duplicate(0, 24)
    end
  end

  defp push1(value), do: <<0x60, value>>

  defp mstore8(offset, byte), do: IO.iodata_to_binary([push1(byte), push1(offset), <<0x53>>])

  defp mcopy(dst, src, length),
    do: IO.iodata_to_binary([push1(length), push1(src), push1(dst), <<0x5E>>])

  defp mload(offset), do: IO.iodata_to_binary([push1(offset), <<0x51>>])

  defp bytes32(word), do: :binary.bin_to_list(<<word::unsigned-big-integer-size(256)>>)
end
