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

  alias EEVM.Config
  alias EEVM.Precompiles.BN256Add
  alias EEVM.Precompiles.BN256Mul
  alias EEVM.Precompiles.BN256Pairing
  alias EEVM.Precompiles.Blake2F
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
  def registry(%Config{precompiles: custom_precompiles}) do
    Map.merge(@default_registry, custom_precompiles)
  end
end
