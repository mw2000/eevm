defmodule EEVM.Precompiles.ECRecover do
  @moduledoc """
  ECRecover precompile at `0x01`. Flat 3000 gas. Input is normalized to
  `hash(32) || v(32) || r(32) || s(32)` (right-padded with zeros if shorter).
  Returns the recovered 20-byte address left-padded to 32 bytes on success;
  empty bytes on any validation failure (gas is still charged). Backed by
  `ExSecp256k1.recover_compact/3`.
  """

  @behaviour EEVM.Precompile

  @gas_cost 3000
  @curve_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  @spec execute(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :out_of_gas}
  @impl true
  def execute(_input, gas_limit) when gas_limit < @gas_cost, do: {:error, :out_of_gas}

  def execute(input, _gas_limit) do
    <<hash::binary-size(32), v_word::binary-size(32), r_bin::binary-size(32),
      s_bin::binary-size(32)>> =
      normalize_input(input)

    with {:ok, recovery_id} <- parse_v(v_word),
         {:ok, r, s} <- parse_signature_scalars(r_bin, s_bin),
         {:ok, public_key} <- recover_public_key(hash, r, s, recovery_id),
         {:ok, address} <- derive_address(public_key) do
      {:ok, <<0::96, address::binary-size(20)>>, @gas_cost}
    else
      :error -> {:ok, <<>>, @gas_cost}
    end
  end

  defp normalize_input(input) when byte_size(input) >= 128, do: binary_part(input, 0, 128)

  defp normalize_input(input) do
    input <> :binary.copy(<<0>>, 128 - byte_size(input))
  end

  defp parse_v(<<0::248, 27>>), do: {:ok, 0}
  defp parse_v(<<0::248, 28>>), do: {:ok, 1}
  defp parse_v(_), do: :error

  defp parse_signature_scalars(r_bin, s_bin) do
    r = :binary.decode_unsigned(r_bin)
    s = :binary.decode_unsigned(s_bin)

    if valid_scalar?(r) and valid_scalar?(s) do
      {:ok, r, s}
    else
      :error
    end
  end

  defp valid_scalar?(value), do: value > 0 and value < @curve_order

  defp recover_public_key(hash, r, s, recovery_id) do
    signature = <<r::unsigned-big-256, s::unsigned-big-256>>

    case ExSecp256k1.recover_compact(hash, signature, recovery_id) do
      {:ok, public_key} when byte_size(public_key) == 65 -> {:ok, public_key}
      _ -> :error
    end
  end

  defp derive_address(<<4, uncompressed_key::binary-size(64)>>) do
    <<_::binary-size(12), address::binary-size(20)>> = ExKeccak.hash_256(uncompressed_key)
    {:ok, address}
  end

  defp derive_address(_), do: :error
end
