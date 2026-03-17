defmodule EEVM.Precompiles.Blake2FTest do
  use ExUnit.Case, async: true

  alias EEVM.Precompiles.Blake2F

  @vector1_input_hex "0000000c48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000001"
  @vector1_output_hex "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"

  @vector2_input_hex "0000000048c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000001"
  @vector2_output_hex "08c9bcf367e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d282e6ad7f520e511f6c3e2b8c68059b9442be0454267ce079217e1319cde05b"

  describe "execute/2" do
    test "matches EIP-152 test vector (12 rounds)" do
      input = Base.decode16!(@vector1_input_hex, case: :lower)
      expected = Base.decode16!(@vector1_output_hex, case: :lower)

      assert {:ok, output, 12} = Blake2F.execute(input, 12)
      assert output == expected
    end

    test "matches EIP-152 test vector (0 rounds)" do
      input = Base.decode16!(@vector2_input_hex, case: :lower)
      expected = Base.decode16!(@vector2_output_hex, case: :lower)

      assert {:ok, output, 0} = Blake2F.execute(input, 0)
      assert output == expected
    end

    test "invalid input length returns invalid_input" do
      assert {:error, :invalid_input} = Blake2F.execute(<<0::8>>, 1_000)
      assert {:error, :invalid_input} = Blake2F.execute(:binary.copy(<<0x00>>, 212), 1_000)
      assert {:error, :invalid_input} = Blake2F.execute(:binary.copy(<<0x00>>, 214), 1_000)
    end

    test "invalid final block flag returns invalid_input" do
      input = Base.decode16!(@vector1_input_hex, case: :lower)
      <<prefix::binary-size(212), _::unsigned-8>> = input
      invalid_flag_input = <<prefix::binary, 2::unsigned-8>>

      assert {:error, :invalid_input} = Blake2F.execute(invalid_flag_input, 1_000)
    end

    test "gas used equals rounds" do
      base_input = Base.decode16!(@vector1_input_hex, case: :lower)

      for rounds <- [1, 5, 12, 25] do
        input = replace_rounds(base_input, rounds)
        assert {:ok, output, ^rounds} = Blake2F.execute(input, rounds + 10)
        assert byte_size(output) == 64
      end
    end

    test "out of gas when gas_limit < rounds" do
      input = Base.decode16!(@vector1_input_hex, case: :lower)
      assert {:error, :out_of_gas} = Blake2F.execute(input, 11)
    end

    test "exact gas limit equal to rounds succeeds" do
      input = Base.decode16!(@vector1_input_hex, case: :lower)
      assert {:ok, _output, 12} = Blake2F.execute(input, 12)
    end

    test "zero rounds costs 0 gas" do
      input = Base.decode16!(@vector2_input_hex, case: :lower)
      assert {:ok, _output, 0} = Blake2F.execute(input, 0)
    end
  end

  describe "EEVM.Precompiles dispatcher" do
    test "routes address 0x09 to Blake2F" do
      input = Base.decode16!(@vector2_input_hex, case: :lower)
      expected = Base.decode16!(@vector2_output_hex, case: :lower)

      assert {:ok, output, 0} = EEVM.Precompiles.execute(0x09, input, 0)
      assert output == expected
    end
  end

  defp replace_rounds(input, rounds) do
    <<_::unsigned-big-32, rest::binary>> = input
    <<rounds::unsigned-big-32, rest::binary>>
  end
end
