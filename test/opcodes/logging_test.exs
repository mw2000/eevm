defmodule EEVM.Opcodes.LoggingTest do
  use ExUnit.Case, async: true

  alias EEVM.Context.Contract
  alias EEVM.Gas

  describe "LOG opcodes" do
    # ── LOG0–LOG4 Tests ──────

    test "LOG0 empty data (0-byte log, no topics)" do
      code = <<0x60, 0x00, 0x60, 0x00, 0xA0, 0x00>>
      result = EEVM.execute(code)

      assert EEVM.logs(result) == [%{address: 0, data: <<>>, topics: []}]
    end

    test "LOG0 with data reads memory bytes" do
      code =
        <<
          0x60,
          0xAA,
          0x60,
          0x00,
          0x53,
          0x60,
          0xBB,
          0x60,
          0x01,
          0x53,
          0x60,
          0xCC,
          0x60,
          0x02,
          0x53,
          0x60,
          0x03,
          0x60,
          0x00,
          0xA0,
          0x00
        >>

      result = EEVM.execute(code)
      assert EEVM.logs(result) == [%{address: 0, data: <<0xAA, 0xBB, 0xCC>>, topics: []}]
    end

    test "LOG1 single topic" do
      code = <<0x60, 0x2A, 0x60, 0x00, 0x60, 0x00, 0xA1, 0x00>>
      result = EEVM.execute(code)

      assert EEVM.logs(result) == [%{address: 0, data: <<>>, topics: [0x2A]}]
    end

    test "LOG2 two topics" do
      code = <<0x60, 0x22, 0x60, 0x11, 0x60, 0x00, 0x60, 0x00, 0xA2, 0x00>>
      result = EEVM.execute(code)

      assert EEVM.logs(result) == [%{address: 0, data: <<>>, topics: [0x11, 0x22]}]
    end

    test "LOG3 three topics" do
      code = <<0x60, 0x03, 0x60, 0x02, 0x60, 0x01, 0x60, 0x00, 0x60, 0x00, 0xA3, 0x00>>
      result = EEVM.execute(code)

      assert EEVM.logs(result) == [%{address: 0, data: <<>>, topics: [0x01, 0x02, 0x03]}]
    end

    test "LOG4 four topics" do
      code =
        <<
          0x60,
          0x04,
          0x60,
          0x03,
          0x60,
          0x02,
          0x60,
          0x01,
          0x60,
          0x00,
          0x60,
          0x00,
          0xA4,
          0x00
        >>

      result = EEVM.execute(code)
      assert EEVM.logs(result) == [%{address: 0, data: <<>>, topics: [0x01, 0x02, 0x03, 0x04]}]
    end

    test "multiple LOGs accumulate in state.logs list" do
      code =
        <<
          0x60,
          0xAA,
          0x60,
          0x00,
          0x53,
          0x60,
          0x01,
          0x60,
          0x00,
          0xA0,
          0x60,
          0x99,
          0x60,
          0x00,
          0x60,
          0x00,
          0xA1,
          0x00
        >>

      result = EEVM.execute(code)

      assert EEVM.logs(result) == [
               %{address: 0, data: <<0xAA>>, topics: []},
               %{address: 0, data: <<>>, topics: [0x99]}
             ]
    end

    test "gas calculation for LOGn is 375 + 375*N + 8*size" do
      assert Gas.log_cost(0, 0) == 375
      assert Gas.log_cost(2, 10) == 375 + 375 * 2 + 8 * 10
      assert Gas.log_cost(4, 64) == 375 + 375 * 4 + 8 * 64
    end

    test "memory expansion is triggered by LOG data reads beyond current memory" do
      code = <<0x60, 0x40, 0x60, 0x00, 0xA0, 0x00>>
      result = EEVM.execute(code)

      assert result.memory.size == 64
      assert [%{data: data}] = EEVM.logs(result)
      assert byte_size(data) == 64
    end

    test "contract address is attached to emitted logs" do
      code = <<0x60, 0x00, 0x60, 0x00, 0xA0, 0x00>>
      result = EEVM.execute(code, contract: Contract.new(address: 0xCAFE))

      assert EEVM.logs(result) == [%{address: 0xCAFE, data: <<>>, topics: []}]
    end
  end
end
