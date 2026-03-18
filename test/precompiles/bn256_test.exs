defmodule EEVM.Precompiles.BN256Test do
  use ExUnit.Case, async: true

  alias EEVM.Precompiles.BN256

  @g1_x 1
  @g1_y 2

  # G1 generator encoded as 64 bytes
  @g1_encoded <<@g1_x::unsigned-big-256, @g1_y::unsigned-big-256>>
  @zero_point :binary.copy(<<0>>, 64)

  # 2 * G1 (known result from BN128 curve)
  @g1_2x_hex "030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd315ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4"

  describe "ecAdd (0x06)" do
    test "adding two identity points returns identity" do
      input = :binary.copy(<<0>>, 128)
      assert {:ok, output, 150} = BN256.execute_add(input, 1_000)
      assert output == @zero_point
    end

    test "adding point to identity returns same point" do
      input = @g1_encoded <> @zero_point
      assert {:ok, output, 150} = BN256.execute_add(input, 1_000)
      assert output == @g1_encoded
    end

    test "adding identity to point returns same point" do
      input = @zero_point <> @g1_encoded
      assert {:ok, output, 150} = BN256.execute_add(input, 1_000)
      assert output == @g1_encoded
    end

    test "G1 + G1 = 2*G1" do
      input = @g1_encoded <> @g1_encoded
      expected = Base.decode16!(@g1_2x_hex, case: :lower)
      assert {:ok, output, 150} = BN256.execute_add(input, 1_000)
      assert output == expected
    end

    test "out of gas returns error" do
      input = :binary.copy(<<0>>, 128)
      assert {:error, :out_of_gas} = BN256.execute_add(input, 149)
    end

    test "exact gas limit succeeds" do
      input = :binary.copy(<<0>>, 128)
      assert {:ok, _, 150} = BN256.execute_add(input, 150)
    end

    test "short input is zero-padded" do
      assert {:ok, output, 150} = BN256.execute_add(<<>>, 1_000)
      assert output == @zero_point
    end

    test "invalid curve point returns error" do
      input = <<1::256, 1::256>> <> @zero_point
      assert {:error, :invalid_point} = BN256.execute_add(input, 1_000)
    end

    test "coordinate >= field modulus returns error" do
      p =
        21_888_242_871_839_275_222_246_405_745_257_275_088_696_311_157_297_823_662_689_037_894_645_226_208_583

      input = <<p::unsigned-big-256, 0::256>> <> @zero_point
      assert {:error, :invalid_point} = BN256.execute_add(input, 1_000)
    end
  end

  describe "ecMul (0x07)" do
    test "multiply by 0 returns identity" do
      input = @g1_encoded <> <<0::256>>
      assert {:ok, output, 6_000} = BN256.execute_mul(input, 10_000)
      assert output == @zero_point
    end

    test "multiply by 1 returns same point" do
      input = @g1_encoded <> <<1::256>>
      assert {:ok, output, 6_000} = BN256.execute_mul(input, 10_000)
      assert output == @g1_encoded
    end

    test "multiply by 2 matches ecAdd(G1, G1)" do
      mul_input = @g1_encoded <> <<2::256>>
      assert {:ok, mul_output, 6_000} = BN256.execute_mul(mul_input, 10_000)

      add_input = @g1_encoded <> @g1_encoded
      assert {:ok, add_output, 150} = BN256.execute_add(add_input, 1_000)

      assert mul_output == add_output
    end

    test "multiply identity by any scalar returns identity" do
      input = @zero_point <> <<42::256>>
      assert {:ok, output, 6_000} = BN256.execute_mul(input, 10_000)
      assert output == @zero_point
    end

    test "out of gas returns error" do
      input = @g1_encoded <> <<1::256>>
      assert {:error, :out_of_gas} = BN256.execute_mul(input, 5_999)
    end

    test "exact gas limit succeeds" do
      input = @g1_encoded <> <<1::256>>
      assert {:ok, _, 6_000} = BN256.execute_mul(input, 6_000)
    end

    test "short input is zero-padded" do
      assert {:ok, output, 6_000} = BN256.execute_mul(<<>>, 10_000)
      assert output == @zero_point
    end

    test "invalid curve point returns error" do
      input = <<1::256, 1::256, 1::256>>
      assert {:error, :invalid_point} = BN256.execute_mul(input, 10_000)
    end
  end

  describe "ecPairing (0x08)" do
    test "empty input returns 1" do
      assert {:ok, output, 45_000} = BN256.execute_pairing(<<>>, 100_000)
      assert output == <<1::256>>
    end

    test "input not divisible by 192 returns error" do
      assert {:error, :invalid_input} = BN256.execute_pairing(<<0>>, 100_000)
      assert {:error, :invalid_input} = BN256.execute_pairing(:binary.copy(<<0>>, 191), 100_000)
      assert {:error, :invalid_input} = BN256.execute_pairing(:binary.copy(<<0>>, 193), 100_000)
    end

    test "out of gas with 0 pairs" do
      assert {:error, :out_of_gas} = BN256.execute_pairing(<<>>, 44_999)
    end

    test "out of gas with 1 pair" do
      input = :binary.copy(<<0>>, 192)
      assert {:error, :out_of_gas} = BN256.execute_pairing(input, 78_999)
    end

    test "gas cost for 0 pairs is 45,000" do
      assert {:ok, _, 45_000} = BN256.execute_pairing(<<>>, 45_000)
    end

    test "gas cost for 1 pair is 79,000" do
      input = :binary.copy(<<0>>, 192)
      assert {:ok, _, 79_000} = BN256.execute_pairing(input, 100_000)
    end

    test "gas cost for 2 pairs is 113,000" do
      input = :binary.copy(<<0>>, 384)
      assert {:ok, _, 113_000} = BN256.execute_pairing(input, 200_000)
    end

    test "all-zero pair (identity points) returns 1" do
      input = :binary.copy(<<0>>, 192)
      assert {:ok, output, 79_000} = BN256.execute_pairing(input, 100_000)
      assert output == <<1::256>>
    end
  end

  describe "EEVM.Precompiles dispatcher" do
    test "routes 0x06 to ecAdd" do
      input = :binary.copy(<<0>>, 128)
      assert {:ok, _, 150} = EEVM.Precompiles.execute(0x06, input, 1_000)
    end

    test "routes 0x07 to ecMul" do
      input = :binary.copy(<<0>>, 96)
      assert {:ok, _, 6_000} = EEVM.Precompiles.execute(0x07, input, 10_000)
    end

    test "routes 0x08 to ecPairing" do
      assert {:ok, _, 45_000} = EEVM.Precompiles.execute(0x08, <<>>, 100_000)
    end
  end
end
