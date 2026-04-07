defmodule EEVM.Precompiles.Bls12381.Nif do
  @moduledoc false

  use Rustler, otp_app: :eevm, crate: "eevm_bls"

  @spec g1_add(binary()) :: {:ok, binary()} | {:error, atom()}
  def g1_add(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec g1_msm(binary()) :: {:ok, binary()} | {:error, atom()}
  def g1_msm(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec g2_add(binary()) :: {:ok, binary()} | {:error, atom()}
  def g2_add(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec g2_msm(binary()) :: {:ok, binary()} | {:error, atom()}
  def g2_msm(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec pairing(binary()) :: {:ok, binary()} | {:error, atom()}
  def pairing(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec map_fp_to_g1(binary()) :: {:ok, binary()} | {:error, atom()}
  def map_fp_to_g1(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec map_fp2_to_g2(binary()) :: {:ok, binary()} | {:error, atom()}
  def map_fp2_to_g2(_input), do: :erlang.nif_error(:nif_not_loaded)
end
