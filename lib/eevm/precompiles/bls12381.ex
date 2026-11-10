defmodule EEVM.Precompiles.Bls12381 do
  @moduledoc """
  BLS12-381 precompiles — addresses `0x0B` through `0x11` (EIP-2537).

  This module owns gas accounting, the EIP-2537 encoding, and input
  validation for the Prague-gated BLS12-381 precompiles. The curve arithmetic
  is `EEVM.Precompiles.Bls12381.Curve`, in pure Elixir.

  ### Encoding and validation

  An Fp element is 64 bytes: 16 zero bytes, then a 48-byte big-endian value
  below p. An Fp2 element c0 + c1·u is c0 then c1. A G1 point is x then y
  (128 bytes), a G2 point x then y in Fp2 (256 bytes), and the point at
  infinity is all zeros. A scalar is 32 big-endian bytes.

  Every input point must be on its curve (ADD included); MSM and pairing
  inputs must also be in the order-r subgroup. Any violation is an error,
  which burns all gas supplied to the call.
  """

  alias EEVM.Precompiles.Bls12381.Curve

  @g1_add_gas 375
  @g2_add_gas 600
  @g1_mul_gas 12_000
  @g2_mul_gas 22_500
  @pairing_base_gas 37_700
  @pairing_per_pair_gas 32_600
  @map_fp_to_g1_gas 5_500
  @map_fp2_to_g2_gas 23_800
  @g1_msm_pair_size 160
  @g2_msm_pair_size 288
  @pairing_pair_size 384
  @p Curve.fp_modulus()

  @g1_discounts [
    1000,
    949,
    848,
    797,
    764,
    750,
    738,
    728,
    719,
    712,
    705,
    698,
    692,
    687,
    682,
    677,
    673,
    669,
    665,
    661,
    658,
    654,
    651,
    648,
    645,
    642,
    640,
    637,
    635,
    632,
    630,
    627,
    625,
    623,
    621,
    619,
    617,
    615,
    613,
    611,
    609,
    608,
    606,
    604,
    603,
    601,
    599,
    598,
    596,
    595,
    593,
    592,
    591,
    589,
    588,
    586,
    585,
    584,
    582,
    581,
    580,
    579,
    577,
    576,
    575,
    574,
    573,
    572,
    570,
    569,
    568,
    567,
    566,
    565,
    564,
    563,
    562,
    561,
    560,
    559,
    558,
    557,
    556,
    555,
    554,
    553,
    552,
    551,
    550,
    549,
    548,
    547,
    547,
    546,
    545,
    544,
    543,
    542,
    541,
    540,
    540,
    539,
    538,
    537,
    536,
    536,
    535,
    534,
    533,
    532,
    532,
    531,
    530,
    529,
    528,
    528,
    527,
    526,
    525,
    525,
    524,
    523,
    522,
    522,
    521,
    520,
    520,
    519
  ]

  @g2_discounts [
    1000,
    1000,
    923,
    884,
    855,
    832,
    812,
    796,
    782,
    770,
    759,
    749,
    740,
    732,
    724,
    717,
    711,
    704,
    699,
    693,
    688,
    683,
    679,
    674,
    670,
    666,
    663,
    659,
    655,
    652,
    649,
    646,
    643,
    640,
    637,
    634,
    632,
    629,
    627,
    624,
    622,
    620,
    618,
    615,
    613,
    611,
    609,
    607,
    606,
    604,
    602,
    600,
    598,
    597,
    595,
    593,
    592,
    590,
    589,
    587,
    586,
    584,
    583,
    582,
    580,
    579,
    578,
    576,
    575,
    574,
    573,
    571,
    570,
    569,
    568,
    567,
    566,
    565,
    563,
    562,
    561,
    560,
    559,
    558,
    557,
    556,
    555,
    554,
    553,
    552,
    552,
    551,
    550,
    549,
    548,
    547,
    546,
    545,
    545,
    544,
    543,
    542,
    541,
    541,
    540,
    539,
    538,
    537,
    537,
    536,
    535,
    535,
    534,
    533,
    532,
    532,
    531,
    530,
    530,
    529,
    528,
    528,
    527,
    526,
    526,
    525,
    524,
    524
  ]

  @doc "BLS12_G1ADD (`0x0B`): adds two G1 points. Costs 375 gas."
  @spec execute_g1_add(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_g1_add(input, gas_limit),
    do: execute_with_cost(input, gas_limit, @g1_add_gas, &g1_add/1)

  @doc "BLS12_G2ADD (`0x0D`): adds two G2 points. Costs 600 gas."
  @spec execute_g2_add(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_g2_add(input, gas_limit),
    do: execute_with_cost(input, gas_limit, @g2_add_gas, &g2_add/1)

  @doc """
  BLS12_PAIRING_CHECK (`0x0F`): returns 1 as a 32-byte word if the product of
  the pairings of the given (G1, G2) pairs is 1, else 0. Costs
  37,700 + 32,600 per pair.
  """
  @spec execute_pairing(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_pairing(input, gas_limit) do
    gas_cost =
      @pairing_base_gas + @pairing_per_pair_gas * div(byte_size(input), @pairing_pair_size)

    execute_with_cost(input, gas_limit, gas_cost, &pairing/1)
  end

  @doc "BLS12_MAP_FP_TO_G1 (`0x10`): maps an Fp element to G1. Costs 5,500 gas."
  @spec execute_map_fp_to_g1(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_map_fp_to_g1(input, gas_limit),
    do: execute_with_cost(input, gas_limit, @map_fp_to_g1_gas, &map_fp_to_g1/1)

  @doc "BLS12_MAP_FP2_TO_G2 (`0x11`): maps an Fp2 element to G2. Costs 23,800 gas."
  @spec execute_map_fp2_to_g2(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_map_fp2_to_g2(input, gas_limit),
    do: execute_with_cost(input, gas_limit, @map_fp2_to_g2_gas, &map_fp2_to_g2/1)

  @doc """
  BLS12_G1MSM (`0x0C`): returns Σ kᵢ·Pᵢ over (G1 point, scalar) pairs. Costs
  12,000 gas per pair times the EIP-2537 discount for the pair count.
  """
  @spec execute_g1_msm(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_g1_msm(input, gas_limit) do
    gas_cost = msm_gas_cost(byte_size(input), @g1_msm_pair_size, @g1_mul_gas, @g1_discounts)

    execute_with_cost(
      input,
      gas_limit,
      gas_cost,
      &msm(&1, @g1_msm_pair_size, fn point -> decode_g1(point) end)
    )
  end

  @doc """
  BLS12_G2MSM (`0x0E`): returns Σ kᵢ·Qᵢ over (G2 point, scalar) pairs. Costs
  22,500 gas per pair times the EIP-2537 discount for the pair count.
  """
  @spec execute_g2_msm(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_g2_msm(input, gas_limit) do
    gas_cost = msm_gas_cost(byte_size(input), @g2_msm_pair_size, @g2_mul_gas, @g2_discounts)

    execute_with_cost(
      input,
      gas_limit,
      gas_cost,
      &msm(&1, @g2_msm_pair_size, fn point -> decode_g2(point) end)
    )
  end

  defp execute_with_cost(_input, gas_limit, gas_cost, _fun) when gas_limit < gas_cost,
    do: {:error, :out_of_gas}

  defp execute_with_cost(input, _gas_limit, gas_cost, fun) do
    with {:ok, output} <- fun.(input), do: {:ok, output, gas_cost}
  end

  defp msm_gas_cost(input_length, pair_size, multiplication_cost, discounts) do
    pair_count = div(input_length, pair_size)

    if pair_count == 0 do
      0
    else
      discount = Enum.at(discounts, min(pair_count, length(discounts)) - 1)
      div(pair_count * multiplication_cost * discount, 1_000)
    end
  end

  # --- Operations ---

  # ADD skips the subgroup check (EIP-2537), but not the on-curve check.
  defp g1_add(<<a::binary-size(128), b::binary-size(128)>>) do
    with {:ok, a} <- decode_g1(a),
         {:ok, b} <- decode_g1(b),
         do: {:ok, encode(Curve.add(a, b), 128)}
  end

  defp g1_add(_input), do: {:error, :invalid_input}

  defp g2_add(<<a::binary-size(256), b::binary-size(256)>>) do
    with {:ok, a} <- decode_g2(a),
         {:ok, b} <- decode_g2(b),
         do: {:ok, encode(Curve.add(a, b), 256)}
  end

  defp g2_add(_input), do: {:error, :invalid_input}

  defp msm(input, pair_size, _decode) when input == <<>> or rem(byte_size(input), pair_size) != 0,
    do: {:error, :invalid_input}

  defp msm(input, pair_size, decode) do
    point_size = pair_size - 32

    decode_pair = fn <<point::binary-size(point_size), scalar::unsigned-big-256>> ->
      with {:ok, point} <- decode.(point),
           {:ok, point} <- in_subgroup(point),
           do: {:ok, {point, scalar}}
    end

    with {:ok, pairs} <- decode_chunks(input, pair_size, decode_pair, []) do
      {:ok, encode(Curve.msm(pairs), point_size)}
    end
  end

  defp pairing(input) when input == <<>> or rem(byte_size(input), @pairing_pair_size) != 0,
    do: {:error, :invalid_input}

  defp pairing(input) do
    decode_pair = fn <<p::binary-size(128), q::binary-size(256)>> ->
      with {:ok, p} <- decode_g1(p),
           {:ok, p} <- in_subgroup(p),
           {:ok, q} <- decode_g2(q),
           {:ok, q} <- in_subgroup(q),
           do: {:ok, {p, q}}
    end

    with {:ok, pairs} <- decode_chunks(input, @pairing_pair_size, decode_pair, []) do
      {:ok, if(Curve.pairing_check(pairs), do: <<1::256>>, else: <<0::256>>)}
    end
  end

  defp map_fp_to_g1(<<_::binary-size(64)>> = input) do
    with {:ok, u} <- decode_fp(input), do: {:ok, encode(Curve.map_fp_to_g1(u), 128)}
  end

  defp map_fp_to_g1(_input), do: {:error, :invalid_input}

  defp map_fp2_to_g2(<<_::binary-size(128)>> = input) do
    with {:ok, u} <- decode_fp2(input), do: {:ok, encode(Curve.map_fp2_to_g2(u), 256)}
  end

  defp map_fp2_to_g2(_input), do: {:error, :invalid_input}

  # --- Encoding ---

  defp decode_chunks(<<>>, _size, _decode, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_chunks(input, size, decode, acc) do
    <<chunk::binary-size(size), rest::binary>> = input

    with {:ok, item} <- decode.(chunk), do: decode_chunks(rest, size, decode, [item | acc])
  end

  defp decode_fp(<<0::128, x::384>>) when x < @p, do: {:ok, x}
  defp decode_fp(_bytes), do: {:error, :invalid_input}

  defp decode_fp2(<<c0::binary-size(64), c1::binary-size(64)>>) do
    with {:ok, c0} <- decode_fp(c0), {:ok, c1} <- decode_fp(c1), do: {:ok, {c0, c1}}
  end

  defp decode_g1(<<x::binary-size(64), y::binary-size(64)>>) do
    with {:ok, x} <- decode_fp(x), {:ok, y} <- decode_fp(y), do: on_curve({x, y})
  end

  defp decode_g2(<<x::binary-size(128), y::binary-size(128)>>) do
    with {:ok, x} <- decode_fp2(x), {:ok, y} <- decode_fp2(y), do: on_curve({x, y})
  end

  # All zeros encodes infinity; (0, 0) is on neither curve, so it is free.
  defp on_curve({0, 0}), do: {:ok, :infinity}
  defp on_curve({{0, 0}, {0, 0}}), do: {:ok, :infinity}

  defp on_curve(point),
    do: if(Curve.on_curve?(point), do: {:ok, point}, else: {:error, :invalid_point})

  defp in_subgroup(point),
    do: if(Curve.in_subgroup?(point), do: {:ok, point}, else: {:error, :invalid_point})

  defp encode(:infinity, size), do: <<0::size(size)-unit(8)>>
  defp encode({x, y}, _size) when is_integer(x), do: <<0::128, x::384, 0::128, y::384>>

  defp encode({{x0, x1}, {y0, y1}}, _size),
    do: <<0::128, x0::384, 0::128, x1::384, 0::128, y0::384, 0::128, y1::384>>
end
