defmodule EEVM.Precompiles.ModExpTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias EEVM.Precompiles.ModExp
  alias EEVM.Precompiles.ModExpEIP7883

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

    test "iteration count uses the exponent's bit length, not its byte length" do
      # exp = 0x01FFFFFF has bit length 25 → iteration_count 24; 40-byte operands → 5 words
      base_bytes = :binary.copy(<<0x02>>, 40)
      mod_bytes = :binary.copy(<<0x03>>, 40)
      input = encode_modexp_bytes(base_bytes, <<0x01, 0xFF, 0xFF, 0xFF>>, mod_bytes)

      assert {:ok, _out, 200} = ModExp.execute(input, 1_000_000)
    end

    test "iteration count is floored at 1 for a zero exponent" do
      # 256-byte operands → 32 words → 32² × 1 / 3 = 341 (would be the 200 floor with 0 iterations)
      base_bytes = :binary.copy(<<0x02>>, 256)
      mod_bytes = :binary.copy(<<0x03>>, 256)
      input = encode_modexp_bytes(base_bytes, <<0x00>>, mod_bytes)

      assert {:ok, out, 341} = ModExp.execute(input, 1_000_000)
      assert :binary.decode_unsigned(out) == 1
    end

    test "huge declared base length runs out of gas without allocating operands" do
      input = <<1 <<< 64::256, 1::256, 1::256, 0x03, 0x05>>
      assert {:error, :out_of_gas} = ModExp.execute(input, 30_000_000)

      input = <<(1 <<< 256) - 1::256, 0::256, 1::256>>
      assert {:error, :out_of_gas} = ModExp.execute(input, 30_000_000)
    end

    test "huge declared exponent length with empty base and modulus costs the minimum" do
      input = <<0::256, (1 <<< 256) - 1::256, 0::256, 0xFF>>
      assert {:ok, <<>>, 200} = ModExp.execute(input, 200)
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

  describe "official EIP-2565 / EIP-7883 vectors" do
    # Each vector carries the expected output and both gas schedules (GasOld = EIP-2565,
    # GasNew = EIP-7883); see test/fixtures/precompiles/README.md for the source.
    for vector <-
          "test/fixtures/precompiles/modexp_eip7883_vectors.json"
          |> File.read!()
          |> Jason.decode!() do
      @vector vector
      test "#{vector["Name"]}" do
        input = Base.decode16!(@vector["Input"], case: :mixed)
        expected = Base.decode16!(@vector["Expected"], case: :mixed)
        gas_old = @vector["GasOld"]
        gas_new = @vector["GasNew"]

        assert {:ok, ^expected, ^gas_old} = ModExp.execute(input, 100_000_000)
        assert {:ok, ^expected, ^gas_new} = ModExpEIP7883.execute(input, 100_000_000)
        assert {:error, :out_of_gas} = ModExpEIP7883.execute(input, gas_new - 1)
      end
    end
  end

  describe "EIP-7883 pricing" do
    test "minimum cost rises from 200 to 500" do
      assert {:ok, <<>>, 500} = ModExpEIP7883.execute(<<>>, 500)
      assert {:error, :out_of_gas} = ModExpEIP7883.execute(<<>>, 499)
    end

    test "exponent bytes past 32 count 16 iterations each instead of 8" do
      # 64-byte operands → 2 × 8² = 128; exp = 0x80 ‖ 32 zero bytes → 16 × 1 + 255 = 271
      base_bytes = <<0x01, 0::size(63 * 8)>>
      exp_bytes = <<0x80, 0::size(32 * 8)>>
      mod_bytes = <<0x01, 0::size(63 * 8)>>

      input = encode_modexp_bytes(base_bytes, exp_bytes, mod_bytes)
      assert {:ok, _out, 34_688} = ModExpEIP7883.execute(input, 1_000_000)
    end
  end

  describe "EIP-7823 input bounds" do
    # Lengths may be at most 1024 bytes from Osaka; longer inputs fail, consuming all gas.
    for {field, index} <- [base: 0, exponent: 1, modulus: 2] do
      test "#{field} length 1024 is accepted and 1025 is rejected" do
        at_limit = header_with_length(unquote(index), 1024)
        over_limit = header_with_length(unquote(index), 1025)

        assert {:ok, _out, _gas} = ModExpEIP7883.execute(at_limit, 100_000_000)
        assert {:error, :invalid_input} = ModExpEIP7883.execute(over_limit, 100_000_000)
      end
    end

    test "do not apply before Osaka" do
      assert {:ok, _out, _gas} = ModExp.execute(header_with_length(0, 1025), 100_000_000)
    end
  end

  describe "EEVM.Precompiles dispatcher" do
    test "routes address 0x05 to ModExp" do
      input = encode_modexp(2, 10, 1000)
      assert {:ok, out, _gas} = EEVM.Precompiles.execute(0x05, input, 100_000)
      assert :binary.decode_unsigned(out) == 24
    end

    test "applies EIP-2565 pricing through Prague and EIP-7883 pricing from Osaka" do
      input = encode_modexp(2, 10, 1000)

      assert {:ok, _out, 200} =
               EEVM.Precompiles.execute(0x05, input, 100_000, EEVM.Config.new(:prague))

      assert {:ok, _out, 500} =
               EEVM.Precompiles.execute(0x05, input, 100_000, EEVM.Config.new(:osaka))
    end
  end

  defp encode_modexp(base, exp, modulus) do
    base_bytes = if base == 0, do: <<>>, else: :binary.encode_unsigned(base)
    exp_bytes = if exp == 0, do: <<>>, else: :binary.encode_unsigned(exp)
    mod_bytes = if modulus == 0, do: <<>>, else: :binary.encode_unsigned(modulus)

    <<byte_size(base_bytes)::256, byte_size(exp_bytes)::256, byte_size(mod_bytes)::256,
      base_bytes::binary, exp_bytes::binary, mod_bytes::binary>>
  end

  # Header declaring `length` bytes for one field (0 = base, 1 = exponent, 2 = modulus)
  # and 1 byte for the others; operands are implicitly zero-padded.
  defp header_with_length(index, length) do
    for i <- 0..2, into: <<>>, do: <<if(i == index, do: length, else: 1)::256>>
  end

  defp encode_modexp_bytes(base_bytes, exp_bytes, mod_bytes) do
    <<byte_size(base_bytes)::256, byte_size(exp_bytes)::256, byte_size(mod_bytes)::256,
      base_bytes::binary, exp_bytes::binary, mod_bytes::binary>>
  end
end
