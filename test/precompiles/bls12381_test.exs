defmodule EEVM.Precompiles.Bls12381Test do
  use ExUnit.Case, async: true

  alias EEVM.Config
  alias EEVM.Precompiles
  alias EEVM.Precompiles.Bls12381

  @g1_generator_x "17f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb"
  @g1_generator_y "08b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1"
  @g2_generator_x_c0 "024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb8"
  @g2_generator_x_c1 "13e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e"
  @g2_generator_y_c0 "0ce5d527727d6e118cc9cdc6da2e351aadfd9baa8cbdd3a76d429a695160d12c923ac9cc3baca289e193548608b82801"
  @g2_generator_y_c1 "0606c4a02ea734cc32acd2b02bc28b99cb3e287e85a763af267492ab572e99ab3f370d275cec1da1aaa9075ff05f79be"

  @g1_generator <<0::128, Base.decode16!(@g1_generator_x, case: :lower)::binary, 0::128,
                  Base.decode16!(@g1_generator_y, case: :lower)::binary>>
  @g2_generator <<0::128, Base.decode16!(@g2_generator_x_c0, case: :lower)::binary, 0::128,
                  Base.decode16!(@g2_generator_x_c1, case: :lower)::binary, 0::128,
                  Base.decode16!(@g2_generator_y_c0, case: :lower)::binary, 0::128,
                  Base.decode16!(@g2_generator_y_c1, case: :lower)::binary>>
  @g1_infinity :binary.copy(<<0>>, 128)

  describe "G1 add (0x0B)" do
    test "identity plus generator returns generator" do
      assert {:ok, output, 375} = Bls12381.execute_g1_add(@g1_infinity <> @g1_generator, 375)
      assert output == @g1_generator
    end

    test "out of gas returns error" do
      assert {:error, :out_of_gas} = Bls12381.execute_g1_add(@g1_infinity <> @g1_generator, 374)
    end
  end

  describe "G1 MSM (0x0C)" do
    test "single generator with scalar 1 returns generator" do
      input = @g1_generator <> <<1::unsigned-big-256>>
      assert {:ok, output, 12_000} = Bls12381.execute_g1_msm(input, 12_000)
      assert output == @g1_generator
    end

    test "empty input is invalid" do
      assert {:error, :invalid_input} = Bls12381.execute_g1_msm(<<>>, 0)
    end
  end

  describe "G2 add (0x0D)" do
    test "identity plus generator returns generator" do
      input = :binary.copy(<<0>>, 256) <> @g2_generator
      assert {:ok, output, 600} = Bls12381.execute_g2_add(input, 600)
      assert output == @g2_generator
    end
  end

  describe "G2 MSM (0x0E)" do
    test "single generator with scalar 1 returns generator" do
      input = @g2_generator <> <<1::unsigned-big-256>>
      assert {:ok, output, 22_500} = Bls12381.execute_g2_msm(input, 22_500)
      assert output == @g2_generator
    end
  end

  describe "pairing (0x0F)" do
    test "infinity G1 paired with generator G2 returns 1" do
      input = @g1_infinity <> @g2_generator
      assert {:ok, <<1::unsigned-big-256>>, 70_300} = Bls12381.execute_pairing(input, 70_300)
    end

    test "empty input is invalid even though gas cost is base cost" do
      assert {:error, :invalid_input} = Bls12381.execute_pairing(<<>>, 37_700)
    end
  end

  describe "map precompiles (0x10, 0x11)" do
    test "map Fp to G1 returns a non-infinity point" do
      input =
        fp(
          "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
        )

      assert {:ok, output, 5_500} = Bls12381.execute_map_fp_to_g1(input, 5_500)
      assert byte_size(output) == 128
      refute output == @g1_infinity
    end

    test "map Fp2 to G2 returns a non-infinity point" do
      input =
        fp(
          "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
        ) <>
          fp(
            "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002"
          )

      assert {:ok, output, 23_800} = Bls12381.execute_map_fp2_to_g2(input, 23_800)
      assert byte_size(output) == 256
      refute output == :binary.copy(<<0>>, 256)
    end
  end

  describe "dispatcher and Prague gating" do
    test "Prague registers 0x0B through 0x11" do
      config = Config.new(:prague)

      assert Precompiles.precompile_addresses(config) |> Enum.slice(-7, 7) ==
               Enum.to_list(0x0B..0x11)
    end

    test "dispatcher routes 0x0B on Prague and rejects it on Cancun" do
      input = @g1_infinity <> @g1_generator

      assert {:ok, output, 375} = Precompiles.execute(0x0B, input, 375, Config.new(:prague))
      assert output == @g1_generator

      assert {:error, :not_implemented} =
               Precompiles.execute(0x0B, input, 375, Config.new(:cancun))
    end
  end

  defp fp(hex), do: <<0::128, Base.decode16!(hex, case: :lower)::binary>>
end
