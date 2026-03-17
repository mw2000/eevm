defmodule EEVM.Precompiles.IdentityTest do
  use ExUnit.Case, async: true

  alias EEVM.Precompiles.Identity

  describe "execute/2" do
    test "empty input costs 15 gas and returns empty binary" do
      assert {:ok, <<>>, 15} = Identity.execute(<<>>, 1_000)
    end

    test "returns input unchanged" do
      input = <<1, 2, 3, 4, 5>>
      assert {:ok, ^input, _gas} = Identity.execute(input, 1_000)
    end

    test "1-byte input costs 18 gas (base 15 + 1 word × 3)" do
      assert {:ok, _, 18} = Identity.execute(<<0xFF>>, 1_000)
    end

    test "exact 32-byte input costs 18 gas (1 word)" do
      input = :binary.copy(<<0xAB>>, 32)
      assert {:ok, ^input, 18} = Identity.execute(input, 1_000)
    end

    test "33-byte input costs 21 gas (2 words)" do
      input = :binary.copy(<<0x01>>, 33)
      assert {:ok, ^input, 21} = Identity.execute(input, 1_000)
    end

    test "64-byte input costs 21 gas (2 words)" do
      input = :binary.copy(<<0x42>>, 64)
      assert {:ok, ^input, 21} = Identity.execute(input, 1_000)
    end

    test "out of gas when gas_limit < 15 on empty input" do
      assert {:error, :out_of_gas} = Identity.execute(<<>>, 14)
    end

    test "out of gas when gas_limit < cost for non-empty input" do
      # 32-byte input costs 18; 17 gas is not enough
      input = :binary.copy(<<0x00>>, 32)
      assert {:error, :out_of_gas} = Identity.execute(input, 17)
    end

    test "exact gas_limit equal to cost succeeds" do
      assert {:ok, _, 15} = Identity.execute(<<>>, 15)
    end
  end

  describe "EEVM.Precompiles dispatcher" do
    test "routes address 0x04 to Identity" do
      assert {:ok, <<1, 2, 3>>, _} = EEVM.Precompiles.execute(0x04, <<1, 2, 3>>, 1_000)
    end

    test "unknown address falls through to not_implemented" do
      assert {:error, :not_implemented} = EEVM.Precompiles.execute(0x99, <<>>, 1_000)
    end
  end
end
