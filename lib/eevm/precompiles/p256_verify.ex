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

  Verification is `EEVM.Crypto.ECDSA.verify/5`, which rejects a
  point-at-infinity `R'` and compares `R'.x mod n` against `r`, as EIP-7951
  requires.
  """

  @behaviour EEVM.Precompile

  alias EEVM.Crypto.ECDSA

  @gas_cost 6900

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

  # `ECDSA.verify/5` checks the ranges of r and s, that (qx, qy) is on the
  # curve with coordinates below p, and R' itself.
  defp valid_signature?(<<hash::binary-size(32), r::256, s::256, qx::256, qy::256>>),
    do: ECDSA.verify(:p256, hash, r, s, {qx, qy})

  defp valid_signature?(_input), do: false
end
