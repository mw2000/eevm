defmodule EEVM.Precompiles.P256Verify do
  @moduledoc """
  P256VERIFY precompile — address `0x100` (EIP-7951, Osaka onward).

  Verifies an ECDSA signature over secp256r1 (NIST P-256).

  ### Gas schedule

  Flat `6900` gas, charged whether or not the signature verifies.

  ### Input format

  Exactly 160 bytes: `hash(32) || r(32) || s(32) || qx(32) || qy(32)`.

  ### Output format

  32-byte `0x00..01` when the signature is valid; empty output when it is not
  or when the input fails validation (wrong length, `r`/`s` outside `(0, n)`,
  `qx`/`qy` not below `p`, or `(qx, qy)` not on the curve, which also rejects
  the `(0, 0)` point-at-infinity encoding). The precompile never reverts.

  Verification delegates to OpenSSL's ECDSA via `:crypto.verify/5`, which
  rejects a point-at-infinity `R'` and compares `R'.x mod n` against `r`, as
  EIP-7951 requires.
  """

  @behaviour EEVM.Precompile

  @gas_cost 6900

  # secp256r1 domain parameters (NIST SP 800-186)
  @p 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @a 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFC
  @b 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
  @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  @doc """
  Executes the P256VERIFY precompile.
  """
  @spec execute(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :out_of_gas}
  @impl true
  def execute(_input, gas_limit) when gas_limit < @gas_cost, do: {:error, :out_of_gas}

  def execute(input, _gas_limit) do
    output = if valid_signature?(input), do: <<1::256>>, else: <<>>
    {:ok, output, @gas_cost}
  end

  defp valid_signature?(<<hash::binary-size(32), r::256, s::256, qx::256, qy::256>>)
       when r > 0 and r < @n and s > 0 and s < @n and qx < @p and qy < @p do
    on_curve?(qx, qy) and
      :crypto.verify(
        :ecdsa,
        :sha256,
        {:digest, hash},
        der_signature(r, s),
        [<<4, qx::256, qy::256>>, :secp256r1]
      )
  end

  defp valid_signature?(_input), do: false

  defp on_curve?(x, y), do: Integer.mod(y * y - (x * x * x + @a * x + @b), @p) == 0

  # ASN.1 DER `SEQUENCE { INTEGER r, INTEGER s }`; both fit in 33 bytes, so
  # every length fits in a single short-form byte.
  defp der_signature(r, s) do
    body = der_integer(r) <> der_integer(s)
    <<0x30, byte_size(body), body::binary>>
  end

  defp der_integer(value) do
    bytes =
      case :binary.encode_unsigned(value) do
        <<1::1, _::bitstring>> = high_bit_set -> <<0, high_bit_set::binary>>
        bytes -> bytes
      end

    <<0x02, byte_size(bytes), bytes::binary>>
  end
end
