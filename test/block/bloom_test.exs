defmodule EEVM.BloomTest do
  use ExUnit.Case, async: true

  alias EEVM.Block.Bloom
  alias EEVM.Context.Contract

  describe "empty bloom" do
    test "empty/0 returns 256 zero bytes" do
      assert Bloom.empty() == <<0::2048>>
      assert byte_size(Bloom.empty()) == 256
    end

    test "from_logs/1 with no logs returns empty bloom" do
      assert Bloom.from_logs([]) == Bloom.empty()
    end
  end

  describe "single item insertion" do
    test "address sets deterministic bloom bytes" do
      address = <<1::unsigned-big-160>>
      bloom = Bloom.add(Bloom.empty(), address)

      assert byte_at(bloom, 57) == 0x02
      assert byte_at(bloom, 114) == 0x01
      assert byte_at(bloom, 239) == 0x01
    end

    test "topic sets deterministic bloom bytes" do
      topic = <<1::unsigned-big-256>>
      bloom = Bloom.add(Bloom.empty(), topic)

      assert byte_at(bloom, 61) == 0x04
      assert byte_at(bloom, 85) == 0x04
      assert byte_at(bloom, 222) == 0x40
    end
  end

  describe "from_logs/1 integration" do
    test "single log with address and topics sets all probes" do
      log = %{address: 0xCAFE, topics: [0x01, 0x02], data: <<0xAA, 0xBB>>}
      bloom = Bloom.from_logs([log])

      assert Bloom.contains?(bloom, <<0xCAFE::unsigned-big-160>>)
      assert Bloom.contains?(bloom, <<1::unsigned-big-256>>)
      assert Bloom.contains?(bloom, <<2::unsigned-big-256>>)
    end

    test "multiple logs accumulate address and topic probes" do
      logs = [
        %{address: 0x1111, topics: [0xAAA], data: <<>>},
        %{address: 0x2222, topics: [0xBBB, 0xCCC], data: <<0x01>>}
      ]

      bloom = Bloom.from_logs(logs)

      assert Bloom.contains?(bloom, <<0x1111::unsigned-big-160>>)
      assert Bloom.contains?(bloom, <<0x2222::unsigned-big-160>>)
      assert Bloom.contains?(bloom, <<0xAAA::unsigned-big-256>>)
      assert Bloom.contains?(bloom, <<0xBBB::unsigned-big-256>>)
      assert Bloom.contains?(bloom, <<0xCCC::unsigned-big-256>>)
    end
  end

  describe "contains?/2" do
    test "returns true for inserted item" do
      item = <<0x1234::unsigned-big-256>>
      bloom = Bloom.add(Bloom.empty(), item)

      assert Bloom.contains?(bloom, item)
    end

    test "returns false for item not inserted (high probability)" do
      inserted = <<0x1234::unsigned-big-256>>
      missing = <<0xDEAD_BEEF::unsigned-big-256>>
      bloom = Bloom.add(Bloom.empty(), inserted)

      refute Bloom.contains?(bloom, missing)
    end
  end

  describe "merge/2" do
    test "merged bloom contains items from both inputs" do
      left_item = <<0x1111::unsigned-big-256>>
      right_item = <<0x2222::unsigned-big-256>>

      left = Bloom.add(Bloom.empty(), left_item)
      right = Bloom.add(Bloom.empty(), right_item)
      merged = Bloom.merge(left, right)

      assert Bloom.contains?(merged, left_item)
      assert Bloom.contains?(merged, right_item)
    end
  end

  describe "known vector" do
    test "from_logs/1 matches expected 256-byte bloom" do
      log = %{
        address: 0x0000000000000000000000000000000000000001,
        topics: [0x0000000000000000000000000000000000000000000000000000000000000001],
        data: <<>>
      }

      expected =
        Base.decode16!(
          "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000040000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000100000000000000000000000000000000",
          case: :lower
        )

      assert Bloom.from_logs([log]) == expected
    end
  end

  describe "EEVM logs_bloom/1 integration" do
    test "LOG1 execution produces non-empty bloom" do
      code = <<0x60, 0x2A, 0x60, 0x00, 0x60, 0x00, 0xA1, 0x00>>
      result = EEVM.execute(code, contract: Contract.new(address: 0xABCD))

      assert EEVM.logs(result) != []
      refute EEVM.logs_bloom(result) == Bloom.empty()
    end

    test "execution with no logs produces empty bloom" do
      result = EEVM.execute(<<0x00>>)

      assert EEVM.logs(result) == []
      assert EEVM.logs_bloom(result) == Bloom.empty()
    end
  end

  defp byte_at(binary, index), do: :binary.at(binary, index)
end
