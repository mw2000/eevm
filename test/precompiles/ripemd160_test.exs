defmodule EEVM.Precompiles.RIPEMD160Test do
  use ExUnit.Case, async: true

  alias EEVM.Precompiles.RIPEMD160

  # RIPEMD-160 test vectors from the reference implementation.
  @empty_hash "9c1185a5c5e9fc54612808977ee8f548b2258d31"
  @abc_hash "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc"
  @hello_hash "108f07b8382412612c048d07d13f814118445acd"

  describe "execute/2" do
    test "output is always 32 bytes" do
      assert {:ok, out, _gas} = RIPEMD160.execute(<<>>, 10_000)
      assert byte_size(out) == 32
    end

    test "first 12 bytes are always zero (left-padding)" do
      assert {:ok, out, _gas} = RIPEMD160.execute("anything", 10_000)
      assert binary_part(out, 0, 12) == <<0::96>>
    end

    test "empty input matches reference vector" do
      assert {:ok, out, _gas} = RIPEMD160.execute(<<>>, 10_000)
      hash_hex = out |> binary_part(12, 20) |> Base.encode16(case: :lower)
      assert hash_hex == @empty_hash
    end

    test "ripemd160 of abc matches reference vector" do
      assert {:ok, out, _gas} = RIPEMD160.execute("abc", 10_000)
      hash_hex = out |> binary_part(12, 20) |> Base.encode16(case: :lower)
      assert hash_hex == @abc_hash
    end

    test "ripemd160 of hello matches reference vector" do
      assert {:ok, out, _gas} = RIPEMD160.execute("hello", 10_000)
      hash_hex = out |> binary_part(12, 20) |> Base.encode16(case: :lower)
      assert hash_hex == @hello_hash
    end

    test "empty input costs 600 gas (base only, 0 words)" do
      assert {:ok, _, 600} = RIPEMD160.execute(<<>>, 10_000)
    end

    test "1-byte input costs 720 gas (base 600 + 1 word × 120)" do
      assert {:ok, _, 720} = RIPEMD160.execute(<<0x01>>, 10_000)
    end

    test "exact 32-byte input costs 720 gas (1 word)" do
      input = :binary.copy(<<0xAB>>, 32)
      assert {:ok, _, 720} = RIPEMD160.execute(input, 10_000)
    end

    test "33-byte input costs 840 gas (2 words)" do
      input = :binary.copy(<<0x01>>, 33)
      assert {:ok, _, 840} = RIPEMD160.execute(input, 10_000)
    end

    test "out of gas when gas_limit < 600 on empty input" do
      assert {:error, :out_of_gas} = RIPEMD160.execute(<<>>, 599)
    end

    test "out of gas when gas_limit < cost for non-empty input" do
      # 32-byte input costs 720; 719 gas is not enough
      input = :binary.copy(<<0x00>>, 32)
      assert {:error, :out_of_gas} = RIPEMD160.execute(input, 719)
    end

    test "exact gas_limit equal to cost succeeds" do
      assert {:ok, _, 600} = RIPEMD160.execute(<<>>, 600)
    end
  end

  describe "EEVM.Precompiles dispatcher" do
    test "routes address 0x03 to RIPEMD160" do
      assert {:ok, out, _} = EEVM.Precompiles.execute(0x03, "abc", 10_000)
      hash_hex = out |> binary_part(12, 20) |> Base.encode16(case: :lower)
      assert hash_hex == @abc_hash
    end

    test "unknown address falls through to not_implemented" do
      assert {:error, :not_implemented} = EEVM.Precompiles.execute(0x99, <<>>, 10_000)
    end
  end
end
