defmodule EEVM.Precompiles.SHA256Test do
  use ExUnit.Case, async: true

  alias EEVM.Precompiles.SHA256

  # SHA-256 test vectors from NIST FIPS 180-4.
  @empty_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  @hello_hash "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  @abc_hash "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  describe "execute/2" do
    test "empty input returns 32-byte digest" do
      assert {:ok, digest, _gas} = SHA256.execute(<<>>, 1_000)
      assert byte_size(digest) == 32
    end

    test "empty input matches NIST vector" do
      assert {:ok, digest, _gas} = SHA256.execute(<<>>, 1_000)
      assert Base.encode16(digest, case: :lower) == @empty_hash
    end

    test "sha256 of hello matches NIST vector" do
      assert {:ok, digest, _gas} = SHA256.execute("hello", 1_000)
      assert Base.encode16(digest, case: :lower) == @hello_hash
    end

    test "sha256 of abc matches NIST vector" do
      assert {:ok, digest, _gas} = SHA256.execute("abc", 1_000)
      assert Base.encode16(digest, case: :lower) == @abc_hash
    end

    test "empty input costs 60 gas (base only, 0 words)" do
      assert {:ok, _, 60} = SHA256.execute(<<>>, 1_000)
    end

    test "1-byte input costs 72 gas (base 60 + 1 word × 12)" do
      assert {:ok, _, 72} = SHA256.execute(<<0x01>>, 1_000)
    end

    test "exact 32-byte input costs 72 gas (1 word)" do
      input = :binary.copy(<<0xAB>>, 32)
      assert {:ok, _, 72} = SHA256.execute(input, 1_000)
    end

    test "33-byte input costs 84 gas (2 words)" do
      input = :binary.copy(<<0x01>>, 33)
      assert {:ok, _, 84} = SHA256.execute(input, 1_000)
    end

    test "out of gas when gas_limit < 60 on empty input" do
      assert {:error, :out_of_gas} = SHA256.execute(<<>>, 59)
    end

    test "out of gas when gas_limit < cost for non-empty input" do
      # 32-byte input costs 72; 71 gas is not enough
      input = :binary.copy(<<0x00>>, 32)
      assert {:error, :out_of_gas} = SHA256.execute(input, 71)
    end

    test "exact gas_limit equal to cost succeeds" do
      assert {:ok, _, 60} = SHA256.execute(<<>>, 60)
    end
  end

  describe "EEVM.Precompiles dispatcher" do
    test "routes address 0x02 to SHA256" do
      assert {:ok, digest, _} = EEVM.Precompiles.execute(0x02, "hello", 1_000)
      assert Base.encode16(digest, case: :lower) == @hello_hash
    end

    test "unknown address falls through to not_implemented" do
      assert {:error, :not_implemented} = EEVM.Precompiles.execute(0x99, <<>>, 1_000)
    end
  end
end
