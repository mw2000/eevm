defmodule EEVM.Precompiles do
  @moduledoc """
  Dispatcher for EVM precompiled contracts.

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
  | 0x0B | BLS12 G1ADD — add two BLS12-381 G1 points | EIP-2537 |
  | 0x0C | BLS12 G1MSM — multiscalar multiplication over BLS12-381 G1 | EIP-2537 |
  | 0x0D | BLS12 G2ADD — add two BLS12-381 G2 points | EIP-2537 |
  | 0x0E | BLS12 G2MSM — multiscalar multiplication over BLS12-381 G2 | EIP-2537 |
  | 0x0F | BLS12 PAIRING — pairing check over BLS12-381 | EIP-2537 |
  | 0x10 | BLS12 MAP_FP_TO_G1 — map Fp element into BLS12-381 G1 | EIP-2537 |
  | 0x11 | BLS12 MAP_FP2_TO_G2 — map Fp2 element into BLS12-381 G2 | EIP-2537 |
  """

  alias EEVM.Config
  alias EEVM.HardforkConfig
  alias EEVM.Precompiles.Blake2F
  alias EEVM.Precompiles.BLS12G1Add
  alias EEVM.Precompiles.BLS12G1MSM
  alias EEVM.Precompiles.BLS12G2Add
  alias EEVM.Precompiles.BLS12G2MSM
  alias EEVM.Precompiles.BLS12MapFp2ToG2
  alias EEVM.Precompiles.BLS12MapFpToG1
  alias EEVM.Precompiles.BLS12Pairing
  alias EEVM.Precompiles.BN256Add
  alias EEVM.Precompiles.BN256Mul
  alias EEVM.Precompiles.BN256Pairing
  alias EEVM.Precompiles.ECRecover
  alias EEVM.Precompiles.Identity
  alias EEVM.Precompiles.KZGPointEval
  alias EEVM.Precompiles.ModExp
  alias EEVM.Precompiles.RIPEMD160
  alias EEVM.Precompiles.SHA256

  @default_registry %{
    0x01 => ECRecover,
    0x02 => SHA256,
    0x03 => RIPEMD160,
    0x04 => Identity,
    0x05 => ModExp,
    0x06 => BN256Add,
    0x07 => BN256Mul,
    0x08 => BN256Pairing,
    0x09 => Blake2F,
    0x0A => KZGPointEval
  }

  @eip_2537_registry %{
    0x0B => BLS12G1Add,
    0x0C => BLS12G1MSM,
    0x0D => BLS12G2Add,
    0x0E => BLS12G2MSM,
    0x0F => BLS12Pairing,
    0x10 => BLS12MapFpToG1,
    0x11 => BLS12MapFp2ToG2
  }

  @spec precompile?(non_neg_integer()) :: boolean()
  def precompile?(address), do: precompile?(address, Config.new())

  @spec precompile?(non_neg_integer(), Config.t()) :: boolean()
  def precompile?(address, %Config{} = config) when is_integer(address) and address >= 0 do
    Map.has_key?(registry(config), address)
  end

  def precompile?(_address, _config), do: false

  @spec execute(non_neg_integer(), binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute(address, input, gas_limit), do: execute(address, input, gas_limit, Config.new())

  @spec execute(non_neg_integer(), binary(), non_neg_integer(), Config.t()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def execute(address, input, gas_limit, %Config{} = config)
      when is_integer(address) and is_binary(input) and is_integer(gas_limit) and gas_limit >= 0 do
    case Map.get(registry(config), address) do
      nil -> {:error, :not_implemented}
      module -> module.execute(input, gas_limit)
    end
  end

  @spec precompile_addresses(Config.t()) :: [non_neg_integer()]
  def precompile_addresses(%Config{} = config) do
    config
    |> registry()
    |> Map.keys()
    |> Enum.sort()
  end

  @spec registry(Config.t()) :: %{optional(non_neg_integer()) => module()}
  def registry(%Config{hardfork: hardfork, precompiles: custom_precompiles}) do
    hardfork_registry =
      if HardforkConfig.enabled?(hardfork, :eip_2537) do
        Map.merge(@default_registry, @eip_2537_registry)
      else
        @default_registry
      end

    Map.merge(hardfork_registry, custom_precompiles)
  end
end
