defmodule EEVM.Precompiles.ModExpTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias EEVM.Precompiles.ModExp

  describe "execute/2" do
    test "basic computation: 2^10 mod 1000 = 24" do
      input = encode_modexp(2, 10, 1000)
      assert {:ok, out, _gas} = ModExp.execute(input, 100_000)
      assert :binary.decode_unsigned(out) == 24
    end

    test "base^0 mod N = 1 for N > 1" do
      input = encode_modexp(7, 0, 13)
      assert {:ok, out, _gas} = ModExp.execute(input, 100_000)
      assert :binary.decode_unsigned(out) == 1
    end

    test "0^exp mod N = 0" do
      input = encode_modexp(0, 9, 13)
      assert {:ok, out, _gas} = ModExp.execute(input, 100_000)
      assert :binary.decode_unsigned(out) == 0
    end

    test "modulus = 0 returns zero bytes of mod_length" do
      input = encode_modexp_bytes(<<0x02>>, <<0x0A>>, <<0x00>>)
      assert {:ok, out, _gas} = ModExp.execute(input, 100_000)
      assert out == <<0>>
    end

    test "modulus = 1 returns 0" do
      input = encode_modexp(99, 123, 1)
      assert {:ok, out, _gas} = ModExp.execute(input, 100_000)
      assert :binary.decode_unsigned(out) == 0
    end

    test "large 256-bit values are handled" do
      base = (1 <<< 255) + 12_345
      exp = 1
      modulus = (1 <<< 256) - 189

      input = encode_modexp(base, exp, modulus)
      assert {:ok, out, _gas} = ModExp.execute(input, 1_000_000)
      assert :binary.decode_unsigned(out) == rem(base, modulus)
    end

    test "output is zero-padded to mod_length" do
      input = encode_modexp_bytes(<<0x02>>, <<0x04>>, <<0x00, 0x00, 0x00, 0x11>>)

      assert {:ok, out, _gas} = ModExp.execute(input, 100_000)
      assert out == <<0x00, 0x00, 0x00, 0x10>>
      assert byte_size(out) == 4
    end

    test "gas has minimum of 200" do
      assert {:ok, <<>>, 200} = ModExp.execute(<<>>, 10_000)
    end

    test "gas follows EIP-2565 formula for known input" do
      base_bytes = <<0x01, 0::size(63 * 8)>>
      exp_bytes = <<0x80, 0::size(32 * 8)>>
      mod_bytes = <<0x01, 0::size(63 * 8)>>

      input = encode_modexp_bytes(base_bytes, exp_bytes, mod_bytes)
      assert {:ok, _out, 5_610} = ModExp.execute(input, 1_000_000)
    end

    test "out of gas" do
      assert {:error, :out_of_gas} = ModExp.execute(<<>>, 199)
    end

    test "exact gas limit succeeds" do
      assert {:ok, <<>>, 200} = ModExp.execute(<<>>, 200)
    end

    test "short input (less than 96 bytes) is handled with right-padding" do
      short_input = :binary.copy(<<0x00>>, 95)
      assert {:ok, <<>>, 200} = ModExp.execute(short_input, 10_000)
    end

    test "empty input is handled" do
      assert {:ok, <<>>, 200} = ModExp.execute(<<>>, 10_000)
    end
  end

  describe "EEVM.Precompiles dispatcher" do
    test "routes address 0x05 to ModExp" do
      input = encode_modexp(2, 10, 1000)
      assert {:ok, out, _gas} = EEVM.Precompiles.execute(0x05, input, 100_000)
      assert :binary.decode_unsigned(out) == 24
    end
  end

  defp encode_modexp(base, exp, modulus) do
    base_bytes = if base == 0, do: <<>>, else: :binary.encode_unsigned(base)
    exp_bytes = if exp == 0, do: <<>>, else: :binary.encode_unsigned(exp)
    mod_bytes = if modulus == 0, do: <<>>, else: :binary.encode_unsigned(modulus)

    <<byte_size(base_bytes)::256, byte_size(exp_bytes)::256, byte_size(mod_bytes)::256,
      base_bytes::binary, exp_bytes::binary, mod_bytes::binary>>
  end

  defp encode_modexp_bytes(base_bytes, exp_bytes, mod_bytes) do
    <<byte_size(base_bytes)::256, byte_size(exp_bytes)::256, byte_size(mod_bytes)::256,
      base_bytes::binary, exp_bytes::binary, mod_bytes::binary>>
  end
end
