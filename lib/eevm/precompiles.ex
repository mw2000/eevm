defmodule EEVM.Precompiles do
  @moduledoc """
  Dispatcher for EVM precompiled contracts (addresses 0x01–0x0A).

  Precompiled contracts are built-in functions at fixed addresses that provide
  cryptographic and utility operations too expensive to implement in EVM bytecode.
  When a CALL targets one of these addresses, execution is routed here instead of
  interpreting bytecode.

  ## Supported Precompiles

  | Address | Name | EIP |
  |---------|------|-----|
  | 0x01 | ECRECOVER — elliptic curve signature recovery | Yellow Paper |
  | 0x02 | SHA256 — SHA-256 hash | Yellow Paper |
  | 0x03 | RIPEMD160 — RIPEMD-160 hash | Yellow Paper |
  | 0x04 | IDENTITY — data copy (no-op) | Yellow Paper |
  | 0x05 | MODEXP — big integer modular exponentiation | EIP-198 |
  | 0x06 | BN256 ADD — elliptic curve point addition on alt_bn128 | EIP-196 |
  | 0x07 | BN256 MUL — elliptic curve scalar multiplication on alt_bn128 | EIP-196 |
  | 0x08 | BN256 PAIRING — bilinear pairing check on alt_bn128 | EIP-197 |
  | 0x09 | BLAKE2F — BLAKE2b compression function | EIP-152 |
  | 0x0A | KZG Point Evaluation — verify KZG commitment | EIP-4844 |
  """

  alias EEVM.Precompiles.BN256
  alias EEVM.Precompiles.ECRecover
  alias EEVM.Precompiles.Identity
  alias EEVM.Precompiles.KZGPointEval
  alias EEVM.Precompiles.Blake2F
  alias EEVM.Precompiles.ModExp
  alias EEVM.Precompiles.RIPEMD160
  alias EEVM.Precompiles.SHA256

  @spec precompile?(non_neg_integer()) :: boolean()
  def precompile?(address) when address >= 0x01 and address <= 0x0A, do: true
  def precompile?(_), do: false

  @spec execute(non_neg_integer(), binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute(0x01, input, gas_limit), do: ECRecover.execute(input, gas_limit)
  def execute(0x02, input, gas_limit), do: SHA256.execute(input, gas_limit)
  def execute(0x03, input, gas_limit), do: RIPEMD160.execute(input, gas_limit)
  def execute(0x04, input, gas_limit), do: Identity.execute(input, gas_limit)
  def execute(0x05, input, gas_limit), do: ModExp.execute(input, gas_limit)
  def execute(0x06, input, gas_limit), do: BN256.execute_add(input, gas_limit)
  def execute(0x07, input, gas_limit), do: BN256.execute_mul(input, gas_limit)
  def execute(0x08, input, gas_limit), do: BN256.execute_pairing(input, gas_limit)
  def execute(0x09, input, gas_limit), do: Blake2F.execute(input, gas_limit)
  def execute(0x0A, input, gas_limit), do: KZGPointEval.execute(input, gas_limit)

  def execute(address, input, gas_limit) do
    :erlang.apply(__MODULE__, :do_execute, [address, input, gas_limit])
  end

  def do_execute(_address, _input, _gas_limit) do
    {:error, :not_implemented}
  end
end
