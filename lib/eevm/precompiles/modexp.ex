defmodule EEVM.Precompiles.ModExp do
  @moduledoc """
  Modular exponentiation precompile — address `0x05`.

  ## EVM Concepts

  ModExp computes `base^exp mod modulus` over arbitrarily large integers. It was
  introduced by EIP-198 so contracts can perform heavy number-theoretic
  operations without reimplementing bignum arithmetic in EVM bytecode.

  This precompile is a core primitive for:

  - **RSA signature verification**, where exponentiation modulo a large integer
    is the fundamental operation.
  - **Zero-knowledge proofs**, whose verifier circuits frequently require
    modular exponentiation over large fields.

  ### Gas schedule (EIP-2565)

  The gas charge uses the EIP-2565 repricing formula:

  `gas = max(200, floor(multiplication_complexity * iteration_count / 3))`

  where:

  - `multiplication_complexity = ceil(max(base_length, mod_length) / 8)^2`
    (equivalently `((max(base_length, mod_length) + 7) div 8)^2` in integer
    arithmetic).
  - `iteration_count` is derived from the exponent length and the top bits of
    the exponent:
    - if `exp_length <= 32`: `0` when exponent is zero, otherwise the
      0-indexed highest set bit of the exponent.
    - if `exp_length > 32`: `8 * (exp_length - 32) + highest_bit_index(exp[0..31])`
      where the highest bit index of an all-zero 32-byte prefix is treated as 0.

  ### Input format

  Input is ABI-like (but not standard Solidity ABI):

  - bytes `0..31`: `base_length` (big-endian uint256)
  - bytes `32..63`: `exp_length` (big-endian uint256)
  - bytes `64..95`: `mod_length` (big-endian uint256)
  - bytes `96..`: concatenated `base || exponent || modulus`

  If the input is shorter than required by those lengths, missing bytes are
  treated as zero (right-padding behavior).

  Output is the big-endian value of `base^exp mod modulus`, left-padded with
  zeros to exactly `mod_length` bytes. If `modulus == 0` or `mod_length == 0`,
  the precompile returns `mod_length` zero bytes.

  ## Elixir Learning Notes

  - `:crypto.mod_pow(base, exp, modulus)` delegates modular exponentiation to
    Erlang/OTP's `:crypto` NIF, which uses optimized native big-integer code.
  - `<<len::unsigned-size(256)>>` is binary pattern matching for parsing
    big-endian uint256 fields directly from a binary.
  - Elixir integers are arbitrary precision, so converting between bytes and
    integers with `:binary.decode_unsigned/1` works for very large values.
  """

  @behaviour EEVM.Precompile

  @minimum_gas 200

  @doc """
  Executes the ModExp precompile.
  """
  @spec execute(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :out_of_gas}
  @impl true
  def execute(input, gas_limit) do
    {base_length, exp_length, mod_length, base_bytes, exp_bytes, mod_bytes} = parse_input(input)
    cost = gas_cost(base_length, exp_length, mod_length, exp_bytes)

    if cost > gas_limit do
      {:error, :out_of_gas}
    else
      {:ok, modexp(base_bytes, exp_bytes, mod_bytes, mod_length), cost}
    end
  end

  defp parse_input(input) do
    <<base_length::unsigned-size(256), exp_length::unsigned-size(256),
      mod_length::unsigned-size(256)>> =
      slice_with_right_padding(input, 0, 96)

    base_offset = 96
    exp_offset = base_offset + base_length
    mod_offset = exp_offset + exp_length

    base_bytes = slice_with_right_padding(input, base_offset, base_length)
    exp_bytes = slice_with_right_padding(input, exp_offset, exp_length)
    mod_bytes = slice_with_right_padding(input, mod_offset, mod_length)

    {base_length, exp_length, mod_length, base_bytes, exp_bytes, mod_bytes}
  end

  defp gas_cost(base_length, exp_length, mod_length, exp_bytes) do
    multiplication_complexity =
      max(base_length, mod_length)
      |> Kernel.+(7)
      |> div(8)
      |> square()

    iteration_count = iteration_count(exp_length, exp_bytes)
    max(@minimum_gas, div(multiplication_complexity * iteration_count, 3))
  end

  defp iteration_count(exp_length, exp_bytes) when exp_length <= 32 do
    exponent = :binary.decode_unsigned(exp_bytes)

    if exponent == 0 do
      0
    else
      highest_bit_index(exponent)
    end
  end

  defp iteration_count(exp_length, exp_bytes) do
    first_32_bytes = binary_part(exp_bytes, 0, 32)
    8 * (exp_length - 32) + highest_bit_index(:binary.decode_unsigned(first_32_bytes))
  end

  defp highest_bit_index(0), do: 0
  defp highest_bit_index(value), do: bit_size(:binary.encode_unsigned(value)) - 1

  defp modexp(_base_bytes, _exp_bytes, _mod_bytes, 0), do: <<>>

  defp modexp(base_bytes, exp_bytes, mod_bytes, mod_length) do
    modulus = :binary.decode_unsigned(mod_bytes)

    if modulus == 0 do
      :binary.copy(<<0>>, mod_length)
    else
      base = :binary.decode_unsigned(base_bytes)
      exponent = :binary.decode_unsigned(exp_bytes)
      result = :crypto.mod_pow(base, exponent, modulus)
      left_pad(result, mod_length)
    end
  end

  defp left_pad(binary, size) do
    padding = size - byte_size(binary)

    if padding > 0 do
      :binary.copy(<<0>>, padding) <> binary
    else
      binary
    end
  end

  defp square(value), do: value * value

  defp slice_with_right_padding(_input, _offset, 0), do: <<>>

  defp slice_with_right_padding(input, offset, length) do
    input_size = byte_size(input)

    available =
      if offset < input_size do
        min(length, input_size - offset)
      else
        0
      end

    present =
      if available > 0 do
        binary_part(input, offset, available)
      else
        <<>>
      end

    missing = length - available

    if missing > 0 do
      present <> :binary.copy(<<0>>, missing)
    else
      present
    end
  end
end
