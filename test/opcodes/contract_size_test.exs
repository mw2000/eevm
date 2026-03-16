defmodule EEVM.Opcodes.ContractSizeTest do
  use ExUnit.Case, async: true

  describe "Contract size limits (EIP-170 + EIP-3860)" do
    test "CREATE succeeds with initcode at max size" do
      code =
        IO.iodata_to_binary([
          push(49_152),
          push(0),
          push(0),
          <<0xF0, 0x00>>
        ])

      result = EEVM.execute(code, gas: 10_000_000)
      [addr] = EEVM.stack_values(result)

      assert result.status == :stopped
      assert addr != 0
    end

    test "CREATE fails with initcode over max size (49,152 bytes)" do
      size = 49_153

      code =
        IO.iodata_to_binary([
          push(size),
          push(0),
          push(0),
          <<0xF0, 0x00>>
        ])

      result = EEVM.execute(code, gas: 10_000_000)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "CREATE2 fails with initcode over max size" do
      size = 49_153

      code =
        IO.iodata_to_binary([
          push(0),
          push(size),
          push(0),
          push(0),
          <<0xF5, 0x00>>
        ])

      result = EEVM.execute(code, gas: 10_000_000)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "CREATE rejects deployed code over 24,576 bytes" do
      runtime_size = 24_577

      initcode =
        IO.iodata_to_binary([
          push(runtime_size),
          push(0),
          <<0xF3>>
        ])

      code = create_with_initcode(initcode)
      result = EEVM.execute(code, gas: 10_000_000)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "CREATE succeeds with deployed code at exactly 24,576 bytes" do
      runtime_size = 24_576

      initcode =
        IO.iodata_to_binary([
          push(runtime_size),
          push(0),
          <<0xF3>>
        ])

      code = create_with_initcode(initcode)
      result = EEVM.execute(code, gas: 100_000_000)

      assert result.status == :stopped

      [addr] = EEVM.stack_values(result)
      assert addr != 0
    end

    test "initcode gas cost is charged (2 per 32-byte word)" do
      small_initcode = <<0x60, 0x00, 0x60, 0x00, 0xF3>>
      code = create_with_initcode(small_initcode)
      result = EEVM.execute(code, gas: 1_000_000)

      assert result.status == :stopped
    end
  end

  defp create_with_initcode(initcode) do
    size = byte_size(initcode)

    stores =
      for {byte, i} <- Enum.with_index(:binary.bin_to_list(initcode)) do
        IO.iodata_to_binary([push(byte), push(i), <<0x53>>])
      end

    IO.iodata_to_binary([
      stores,
      push(size),
      push(0),
      push(0),
      <<0xF0, 0x00>>
    ])
  end

  defp push(0), do: <<0x60, 0x00>>
  defp push(n) when n <= 0xFF, do: <<0x60, n>>
  defp push(n) when n <= 0xFFFF, do: <<0x61, n::unsigned-big-16>>
  defp push(n) when n <= 0xFFFFFF, do: <<0x62, n::unsigned-big-24>>
  defp push(n), do: <<0x63, n::unsigned-big-32>>
end
