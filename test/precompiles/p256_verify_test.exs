defmodule EEVM.Precompiles.P256VerifyTest do
  use ExUnit.Case, async: true

  alias EEVM.Config
  alias EEVM.Precompiles
  alias EEVM.Precompiles.P256Verify

  @valid <<1::256>>

  # First vector of the EIP-7951 set: a valid signature.
  @valid_input Base.decode16!(
                 "bb5a52f42f9c9261ed4361f59422a1e30036e7c32b270c8807a419feca605023" <>
                   "2ba3a8be6b94d5ec80a6d9d1190a436effe50d85a1eee859b8cc6af9bd5c2e18" <>
                   "4cd60b855d442f5b3c7b11eb6c4e0ae7525fe710fab9aa7c77a67f79e6fadd76" <>
                   "2927b10512bae3eddcfe467828128bad2903269919f7086069c8c4df6c732838" <>
                   "c7787964eaac00e5921fb1498a60f4606766b3d9685001558d1a974e7341513e",
                 case: :lower
               )

  @p 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  describe "official EIP-7951 vectors" do
    # See test/fixtures/precompiles/README.md for the source.
    for vector <-
          "test/fixtures/precompiles/p256verify_eip7951_vectors.json"
          |> File.read!()
          |> Jason.decode!() do
      @vector vector
      test @vector["Name"] do
        input = Base.decode16!(@vector["Input"], case: :mixed)
        expected = Base.decode16!(@vector["Expected"], case: :mixed)

        assert {:ok, ^expected, 6900} = P256Verify.execute(input, 6900)
      end
    end
  end

  describe "execute/2" do
    test "charges 6900 gas and runs out of gas below it" do
      assert {:ok, @valid, 6900} = P256Verify.execute(@valid_input, 1_000_000)
      assert {:error, :out_of_gas} = P256Verify.execute(@valid_input, 6899)
    end

    test "input must be exactly 160 bytes" do
      assert {:ok, <<>>, 6900} = P256Verify.execute(binary_part(@valid_input, 0, 159), 6900)
      assert {:ok, <<>>, 6900} = P256Verify.execute(@valid_input <> <<0>>, 6900)
      assert {:ok, <<>>, 6900} = P256Verify.execute(<<>>, 6900)
    end

    test "rejects r and s outside (0, n)" do
      <<hash::binary-32, r::256, s::256, key::binary-64>> = @valid_input

      for {bad_r, bad_s} <- [{0, s}, {r, 0}, {@n, s}, {r, @n}] do
        input = <<hash::binary, bad_r::256, bad_s::256, key::binary>>
        assert {:ok, <<>>, 6900} = P256Verify.execute(input, 6900)
      end
    end

    test "rejects public key coordinates that are not below p or not on the curve" do
      <<prefix::binary-96, qx::256, qy::256>> = @valid_input

      for {x, y} <- [{@p, qy}, {qx, @p}, {qx, rem(qy + 1, @p)}, {0, 0}] do
        input = <<prefix::binary, x::256, y::256>>
        assert {:ok, <<>>, 6900} = P256Verify.execute(input, 6900)
      end
    end
  end

  describe "EEVM.Precompiles dispatcher" do
    test "0x100 is registered from Osaka onward" do
      refute Precompiles.precompile?(0x100, Config.new(:prague))
      assert Precompiles.precompile?(0x100, Config.new(:osaka))

      assert {:ok, @valid, 6900} =
               Precompiles.execute(0x100, @valid_input, 10_000, Config.new(:osaka))
    end
  end
end
