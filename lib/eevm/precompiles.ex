defmodule EEVM.Precompiles do
  @moduledoc """
  Dispatcher for EVM precompiled contracts.

  Precompiled contracts are built-in functions at fixed addresses that provide
  cryptographic and utility operations too expensive to implement in EVM bytecode.
  When a CALL targets one of these addresses, execution is routed here instead of
  interpreting bytecode.

  ## Supported Precompiles

  | Address | Name | From |
  |---------|------|------|
  | 0x01 | ECRECOVER — elliptic curve signature recovery | Frontier |
  | 0x02 | SHA256 — SHA-256 hash | Frontier |
  | 0x03 | RIPEMD160 — RIPEMD-160 hash | Frontier |
  | 0x04 | IDENTITY — data copy (no-op) | Frontier |
  | 0x05 | MODEXP — big integer modular exponentiation | Byzantium (EIP-198) |
  | 0x06 | BN256 ADD — elliptic curve point addition on alt_bn128 | Byzantium (EIP-196) |
  | 0x07 | BN256 MUL — elliptic curve scalar multiplication on alt_bn128 | Byzantium (EIP-196) |
  | 0x08 | BN256 PAIRING — bilinear pairing check on alt_bn128 | Byzantium (EIP-197) |
  | 0x09 | BLAKE2F — BLAKE2b compression function | Istanbul (EIP-152) |
  | 0x0A | KZG Point Evaluation — verify KZG commitment | Cancun (EIP-4844) |
  | 0x0B | BLS12 G1ADD — add two BLS12-381 G1 points | Prague (EIP-2537) |
  | 0x0C | BLS12 G1MSM — multiscalar multiplication over BLS12-381 G1 | Prague (EIP-2537) |
  | 0x0D | BLS12 G2ADD — add two BLS12-381 G2 points | Prague (EIP-2537) |
  | 0x0E | BLS12 G2MSM — multiscalar multiplication over BLS12-381 G2 | Prague (EIP-2537) |
  | 0x0F | BLS12 PAIRING — pairing check over BLS12-381 | Prague (EIP-2537) |
  | 0x10 | BLS12 MAP_FP_TO_G1 — map Fp element into BLS12-381 G1 | Prague (EIP-2537) |
  | 0x11 | BLS12 MAP_FP2_TO_G2 — map Fp2 element into BLS12-381 G2 | Prague (EIP-2537) |
  | 0x100 | P256VERIFY — secp256r1 ECDSA signature verification | Osaka (EIP-7951) |

  An address is a precompile only from the fork that introduced it. ModExp and
  the BN256 precompiles also receive the hardfork, because their prices changed
  later: ModExp follows EIP-198, then EIP-2565 (Berlin), then EIP-7883 with the
  EIP-7823 input bounds (Osaka);
  BN256 follows EIP-196/197, then EIP-1108 (Istanbul).

  The registry for each fork is built at compile time. Custom precompiles
  registered through `EEVM.Config.register_precompile/3` implement
  `EEVM.Precompile` and override built-ins at the same address.
  """

  alias EEVM.Config
  alias EEVM.HardforkConfig

  alias EEVM.Precompiles.{
    Blake2F,
    Bls12381,
    BN256,
    ECRecover,
    Identity,
    KZGPointEval,
    ModExp,
    P256Verify,
    RIPEMD160,
    SHA256
  }

  @typedoc """
  How a precompile runs: `apply(module, function, [input, gas_limit | extra_args])`.
  """
  @type entry :: {module(), atom(), list()}

  # {address, activating EIP (nil: Frontier), module, function, receives the hardfork?}
  @builtins [
    {0x01, nil, ECRecover, :execute, false},
    {0x02, nil, SHA256, :execute, false},
    {0x03, nil, RIPEMD160, :execute, false},
    {0x04, nil, Identity, :execute, false},
    {0x05, :eip_198, ModExp, :execute, true},
    {0x06, :eip_196, BN256, :execute_add, true},
    {0x07, :eip_196, BN256, :execute_mul, true},
    {0x08, :eip_197, BN256, :execute_pairing, true},
    {0x09, :eip_152, Blake2F, :execute, false},
    {0x0A, :eip_4844, KZGPointEval, :execute, false},
    {0x0B, :eip_2537, Bls12381, :execute_g1_add, false},
    {0x0C, :eip_2537, Bls12381, :execute_g1_msm, false},
    {0x0D, :eip_2537, Bls12381, :execute_g2_add, false},
    {0x0E, :eip_2537, Bls12381, :execute_g2_msm, false},
    {0x0F, :eip_2537, Bls12381, :execute_pairing, false},
    {0x10, :eip_2537, Bls12381, :execute_map_fp_to_g1, false},
    {0x11, :eip_2537, Bls12381, :execute_map_fp2_to_g2, false},
    {0x100, :eip_7951, P256Verify, :execute, false}
  ]

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
    case registry(config) do
      %{^address => {module, function, extra_args}} ->
        apply(module, function, [input, gas_limit | extra_args])

      _ ->
        {:error, :not_implemented}
    end
  end

  @spec precompile_addresses(Config.t()) :: [non_neg_integer()]
  def precompile_addresses(%Config{} = config) do
    config
    |> registry()
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Returns the precompiles active under `config`: the fork's built-ins merged
  with the custom precompiles registered on `config`.
  """
  @spec registry(Config.t()) :: %{optional(non_neg_integer()) => entry()}
  def registry(%Config{hardfork: %HardforkConfig{spec_id: spec_id}, precompiles: custom}) do
    Enum.reduce(custom, builtins(spec_id), fn {address, module}, registry ->
      Map.put(registry, address, {module, :execute, []})
    end)
  end

  for spec_id <- HardforkConfig.all_spec_ids() do
    hardfork = HardforkConfig.new(spec_id)

    registry =
      for {address, eip, module, function, receives_hardfork?} <- @builtins,
          is_nil(eip) or HardforkConfig.enabled?(hardfork, eip),
          into: %{} do
        {address, {module, function, if(receives_hardfork?, do: [hardfork], else: [])}}
      end

    defp builtins(unquote(spec_id)), do: unquote(Macro.escape(registry))
  end
end
