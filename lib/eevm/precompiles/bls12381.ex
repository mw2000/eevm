defmodule EEVM.Precompiles.Bls12381 do
  @moduledoc """
  BLS12-381 precompiles — addresses `0x0B` through `0x11` (EIP-2537).

  This module owns gas accounting and dispatch for the Prague-gated BLS12-381
  precompiles. The elliptic-curve arithmetic itself is delegated to a Rustler
  NIF backed by Rust code under `native/eevm_bls`.
  """

  alias EEVM.Precompiles.Bls12381.Nif

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

  @spec execute_g1_add(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_g1_add(input, gas_limit),
    do: execute_fixed_cost(input, gas_limit, @g1_add_gas, &Nif.g1_add/1)

  @spec execute_g2_add(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_g2_add(input, gas_limit),
    do: execute_fixed_cost(input, gas_limit, @g2_add_gas, &Nif.g2_add/1)

  @spec execute_pairing(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_pairing(input, gas_limit) do
    gas_cost =
      @pairing_base_gas + @pairing_per_pair_gas * div(byte_size(input), @pairing_pair_size)

    execute_with_cost(input, gas_limit, gas_cost, &Nif.pairing/1)
  end

  @spec execute_map_fp_to_g1(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_map_fp_to_g1(input, gas_limit),
    do: execute_fixed_cost(input, gas_limit, @map_fp_to_g1_gas, &Nif.map_fp_to_g1/1)

  @spec execute_map_fp2_to_g2(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_map_fp2_to_g2(input, gas_limit),
    do: execute_fixed_cost(input, gas_limit, @map_fp2_to_g2_gas, &Nif.map_fp2_to_g2/1)

  @spec execute_g1_msm(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_g1_msm(input, gas_limit) do
    gas_cost = msm_gas_cost(byte_size(input), @g1_msm_pair_size, @g1_mul_gas, @g1_discounts)
    execute_with_cost(input, gas_limit, gas_cost, &Nif.g1_msm/1)
  end

  @spec execute_g2_msm(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute_g2_msm(input, gas_limit) do
    gas_cost = msm_gas_cost(byte_size(input), @g2_msm_pair_size, @g2_mul_gas, @g2_discounts)
    execute_with_cost(input, gas_limit, gas_cost, &Nif.g2_msm/1)
  end

  defp execute_fixed_cost(input, gas_limit, gas_cost, fun),
    do: execute_with_cost(input, gas_limit, gas_cost, fun)

  defp execute_with_cost(_input, gas_limit, gas_cost, _fun) when gas_limit < gas_cost,
    do: {:error, :out_of_gas}

  defp execute_with_cost(input, _gas_limit, gas_cost, fun) do
    case fun.(input) do
      {:ok, output} when is_binary(output) -> {:ok, output, gas_cost}
      {:ok, output} when is_list(output) -> {:ok, IO.iodata_to_binary(output), gas_cost}
      {:ok, {:ok, output}} when is_binary(output) -> {:ok, output, gas_cost}
      {:ok, {:ok, output}} when is_list(output) -> {:ok, IO.iodata_to_binary(output), gas_cost}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
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
end
