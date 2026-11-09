defmodule EEVM.Precompiles.BN256 do
  @moduledoc """
  BN256 (alt_bn128) curve precompiles — addresses `0x06`, `0x07`, `0x08`
  (EIP-196, EIP-197).

  Three operations are exposed:

  - **ecAdd** (`0x06`) — adds two G1 points on the curve.
  - **ecMul** (`0x07`) — performs scalar multiplication on a G1 point.
  - **ecPairing** (`0x08`) — evaluates an optimal Ate pairing check over a list
    of (G1, G2) point pairs.

  ### Gas schedule

  | Operation | Byzantium (EIP-196/197)        | Istanbul on (EIP-1108)        |
  |-----------|--------------------------------|-------------------------------|
  | ecAdd     | 500                            | 150                           |
  | ecMul     | 40,000                         | 6,000                         |
  | ecPairing | 100,000 + 80,000 × pair count  | 45,000 + 34,000 × pair count  |

  Each operation takes the hardfork as an optional third argument (default:
  Cancun) to pick its prices.

  ### Input formats

  - **ecAdd**: 128 bytes — two G1 points, each 64 bytes (x, y as big-endian
    uint256). Short input is right-padded with zeros.
  - **ecMul**: 96 bytes — one G1 point (64 bytes) + scalar (32 bytes).
    Short input is right-padded with zeros.
  - **ecPairing**: `k × 192` bytes — list of (G1, G2) pairs. Each G1 point
    is 64 bytes; each G2 point is 128 bytes encoded as
    `x_imaginary(32) || x_real(32) || y_imaginary(32) || y_real(32)`.
    Input length must be divisible by 192.

  The identity/infinity point is encoded as `(0, 0)`.
  """

  alias BN.{BN128Arithmetic, FQ, FQ2, Pairing}
  alias EEVM.HardforkConfig

  @field_modulus 21_888_242_871_839_275_222_246_405_745_257_275_088_696_311_157_297_823_662_689_037_894_645_226_208_583

  @byzantium_gas %{add: 500, mul: 40_000, pairing_base: 100_000, pairing_per_pair: 80_000}
  @eip_1108_gas %{add: 150, mul: 6_000, pairing_base: 45_000, pairing_per_pair: 34_000}

  @default_hardfork HardforkConfig.new(:cancun)

  # --- ecAdd (0x06) ---

  @doc "Adds two G1 points (ecAdd, `0x06`)."
  @spec execute_add(binary(), non_neg_integer(), HardforkConfig.t()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :out_of_gas | :invalid_point}
  def execute_add(input, gas_limit, hardfork \\ @default_hardfork) do
    %{add: gas_cost} = gas_schedule(hardfork)
    if gas_limit < gas_cost, do: {:error, :out_of_gas}, else: add(input, gas_cost)
  end

  defp add(input, gas_cost) do
    padded = pad_right(input, 128)
    <<x1_bin::binary-32, y1_bin::binary-32, x2_bin::binary-32, y2_bin::binary-32>> = padded

    with {:ok, p1} <- decode_g1_point(x1_bin, y1_bin),
         {:ok, p2} <- decode_g1_point(x2_bin, y2_bin),
         {:ok, result} <- BN128Arithmetic.add(p1, p2) do
      {:ok, encode_g1_point(result), gas_cost}
    else
      {:error, _} -> {:error, :invalid_point}
    end
  end

  # --- ecMul (0x07) ---

  @doc "Multiplies a G1 point by a scalar (ecMul, `0x07`)."
  @spec execute_mul(binary(), non_neg_integer(), HardforkConfig.t()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :out_of_gas | :invalid_point}
  def execute_mul(input, gas_limit, hardfork \\ @default_hardfork) do
    %{mul: gas_cost} = gas_schedule(hardfork)
    if gas_limit < gas_cost, do: {:error, :out_of_gas}, else: mul(input, gas_cost)
  end

  defp mul(input, gas_cost) do
    padded = pad_right(input, 96)
    <<x_bin::binary-32, y_bin::binary-32, scalar_bin::binary-32>> = padded
    scalar = :binary.decode_unsigned(scalar_bin)

    with {:ok, point} <- decode_g1_point(x_bin, y_bin),
         {:ok, result} <- BN128Arithmetic.mult(point, scalar) do
      {:ok, encode_g1_point(result), gas_cost}
    else
      {:error, _} -> {:error, :invalid_point}
    end
  end

  # --- ecPairing (0x08) ---

  @doc "Checks a product of pairings over (G1, G2) pairs (ecPairing, `0x08`)."
  @spec execute_pairing(binary(), non_neg_integer(), HardforkConfig.t()) ::
          {:ok, binary(), non_neg_integer()}
          | {:error, :out_of_gas | :invalid_input | :invalid_point}
  def execute_pairing(input, gas_limit, hardfork \\ @default_hardfork) do
    %{pairing_base: base, pairing_per_pair: per_pair} = gas_schedule(hardfork)
    pair_count = div(byte_size(input), 192)
    gas_cost = base + per_pair * pair_count

    cond do
      rem(byte_size(input), 192) != 0 ->
        {:error, :invalid_input}

      gas_limit < gas_cost ->
        {:error, :out_of_gas}

      pair_count == 0 ->
        {:ok, <<1::256>>, gas_cost}

      true ->
        case decode_pairs(input, pair_count) do
          {:ok, pairs} ->
            result = evaluate_pairing(pairs)
            {:ok, result, gas_cost}

          {:error, _} ->
            {:error, :invalid_point}
        end
    end
  end

  defp gas_schedule(hardfork) do
    if HardforkConfig.enabled?(hardfork, :eip_1108), do: @eip_1108_gas, else: @byzantium_gas
  end

  # --- G1 point encoding/decoding ---

  defp decode_g1_point(x_bin, y_bin) do
    x = :binary.decode_unsigned(x_bin)
    y = :binary.decode_unsigned(y_bin)

    if x == 0 and y == 0 do
      {:ok, {FQ.new(0), FQ.new(0)}}
    else
      if x >= @field_modulus or y >= @field_modulus do
        {:error, :invalid_point}
      else
        point = {FQ.new(x), FQ.new(y)}

        if BN128Arithmetic.on_curve?(point) do
          {:ok, point}
        else
          {:error, :invalid_point}
        end
      end
    end
  end

  defp encode_g1_point({x, y}) do
    x_val = if is_struct(x, FQ), do: x.value, else: 0
    y_val = if is_struct(y, FQ), do: y.value, else: 0
    <<x_val::unsigned-big-256, y_val::unsigned-big-256>>
  end

  # --- G2 point decoding ---

  defp decode_g2_point(x_imag_bin, x_real_bin, y_imag_bin, y_real_bin) do
    x_imag = :binary.decode_unsigned(x_imag_bin)
    x_real = :binary.decode_unsigned(x_real_bin)
    y_imag = :binary.decode_unsigned(y_imag_bin)
    y_real = :binary.decode_unsigned(y_real_bin)

    if x_imag == 0 and x_real == 0 and y_imag == 0 and y_real == 0 do
      {:ok, {FQ2.new([0, 0]), FQ2.new([0, 0])}}
    else
      if x_imag >= @field_modulus or x_real >= @field_modulus or
           y_imag >= @field_modulus or y_real >= @field_modulus do
        {:error, :invalid_point}
      else
        point = {FQ2.new([x_imag, x_real]), FQ2.new([y_imag, y_real])}

        if BN128Arithmetic.on_curve?(point) do
          {:ok, point}
        else
          {:error, :invalid_point}
        end
      end
    end
  end

  # --- Pairing helpers ---

  defp decode_pairs(input, pair_count) do
    decode_pairs_acc(input, pair_count, [])
  end

  defp decode_pairs_acc(_input, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_pairs_acc(
         <<g1_x::binary-32, g1_y::binary-32, g2_x_imag::binary-32, g2_x_real::binary-32,
           g2_y_imag::binary-32, g2_y_real::binary-32, rest::binary>>,
         remaining,
         acc
       ) do
    with {:ok, g1} <- decode_g1_point(g1_x, g1_y),
         {:ok, g2} <- decode_g2_point(g2_x_imag, g2_x_real, g2_y_imag, g2_y_real) do
      decode_pairs_acc(rest, remaining - 1, [{g1, g2} | acc])
    end
  end

  defp evaluate_pairing(pairs) do
    one = BN.FQ12.one()

    product =
      Enum.reduce(pairs, one, fn {g1, g2}, acc ->
        if BN128Arithmetic.infinity?(g1) or BN128Arithmetic.infinity?(g2) do
          acc
        else
          pairing_result = Pairing.pairing(g2, g1)
          BN.FQP.mult(acc, pairing_result)
        end
      end)

    if product == one do
      <<1::256>>
    else
      <<0::256>>
    end
  end

  # --- Utilities ---

  defp pad_right(input, target_size) when byte_size(input) >= target_size do
    binary_part(input, 0, target_size)
  end

  defp pad_right(input, target_size) do
    input <> :binary.copy(<<0>>, target_size - byte_size(input))
  end
end
