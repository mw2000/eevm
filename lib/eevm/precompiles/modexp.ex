defmodule EEVM.Precompiles.ModExp do
  @moduledoc """
  Modular exponentiation precompile — address `0x05` (EIP-198).

  Computes `base^exp mod modulus` over arbitrarily large integers.

  ### Gas schedule (EIP-2565, Berlin through Prague)

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
    - the result is floored at `1`.

  ### Gas schedule (EIP-7883, Osaka onward)

  `gas = max(500, multiplication_complexity * iteration_count)`

  where:

  - `multiplication_complexity` is `16` when `max(base_length, mod_length) <= 32`,
    otherwise `2 * ceil(max(base_length, mod_length) / 8)^2`.
  - `iteration_count` is computed as above, except the per-byte multiplier for
    exponents longer than 32 bytes is `16` instead of `8`.

  `execute/2` applies EIP-2565 pricing; `EEVM.Precompiles` routes `0x05` to
  `EEVM.Precompiles.ModExpEIP7883` once `:eip_7883` is active.

  Gas is charged from the 96-byte header and at most the first 32 exponent
  bytes before any operand is read, so oversized declared lengths fail with
  out-of-gas instead of allocating.

  ### Input format

  - bytes `0..31`: `base_length` (big-endian uint256)
  - bytes `32..63`: `exp_length` (big-endian uint256)
  - bytes `64..95`: `mod_length` (big-endian uint256)
  - bytes `96..`: concatenated `base || exponent || modulus`

  If the input is shorter than required by those lengths, missing bytes are
  treated as zero (right-padding behavior).

  Output is the big-endian value of `base^exp mod modulus`, left-padded with
  zeros to exactly `mod_length` bytes. If `modulus == 0` or `mod_length == 0`,
  the precompile returns `mod_length` zero bytes.
  """

  @behaviour EEVM.Precompile

  @type pricing :: :eip_2565 | :eip_7883

  @doc """
  Executes the ModExp precompile with EIP-2565 pricing.
  """
  @spec execute(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :out_of_gas}
  @impl true
  def execute(input, gas_limit), do: execute(input, gas_limit, :eip_2565)

  @doc """
  Executes the ModExp precompile with the given gas `pricing` rules.
  """
  @spec execute(binary(), non_neg_integer(), pricing()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :out_of_gas}
  def execute(input, gas_limit, pricing) do
    <<base_length::unsigned-size(256), exp_length::unsigned-size(256),
      mod_length::unsigned-size(256)>> = slice_with_right_padding(input, 0, 96)

    # Gas depends only on the header and the exponent's first 32 bytes, so
    # charge it before touching operands whose declared lengths may be huge.
    exp_head = exponent_head(input, base_length, exp_length)
    cost = gas_cost(pricing, base_length, exp_length, mod_length, exp_head)

    if cost > gas_limit do
      {:error, :out_of_gas}
    else
      {:ok, modexp(input, base_length, exp_length, mod_length), cost}
    end
  end

  defp exponent_head(input, base_length, exp_length) do
    input
    |> slice_with_right_padding(96 + base_length, min(exp_length, 32))
    |> :binary.decode_unsigned()
  end

  defp gas_cost(:eip_2565, base_length, exp_length, mod_length, exp_head) do
    multiplication_complexity = square(words(max(base_length, mod_length)))
    iteration_count = iteration_count(exp_length, exp_head, 8)
    max(200, div(multiplication_complexity * iteration_count, 3))
  end

  defp gas_cost(:eip_7883, base_length, exp_length, mod_length, exp_head) do
    max_length = max(base_length, mod_length)
    multiplication_complexity = if max_length > 32, do: 2 * square(words(max_length)), else: 16
    iteration_count = iteration_count(exp_length, exp_head, 16)
    max(500, multiplication_complexity * iteration_count)
  end

  defp words(length), do: div(length + 7, 8)

  # `multiplier` is the per-byte weight of exponent bytes past the first 32.
  defp iteration_count(exp_length, exp_head, _multiplier) when exp_length <= 32,
    do: max(highest_bit_index(exp_head), 1)

  defp iteration_count(exp_length, exp_head, multiplier),
    do: max(multiplier * (exp_length - 32) + highest_bit_index(exp_head), 1)

  defp highest_bit_index(0), do: 0

  defp highest_bit_index(value) do
    <<top_byte, _rest::binary>> = bytes = :binary.encode_unsigned(value)
    (byte_size(bytes) - 1) * 8 + length(Integer.digits(top_byte, 2)) - 1
  end

  # When gas was affordable and mod_length > 0, the operand lengths are
  # bounded by the gas paid, so materializing them is safe.
  defp modexp(_input, _base_length, _exp_length, 0), do: <<>>

  defp modexp(input, base_length, exp_length, mod_length) do
    modulus = read_operand(input, 96 + base_length + exp_length, mod_length)

    if modulus == 0 do
      :binary.copy(<<0>>, mod_length)
    else
      base = read_operand(input, 96, base_length)
      exponent = read_operand(input, 96 + base_length, exp_length)
      result = :crypto.mod_pow(base, exponent, modulus)
      left_pad(result, mod_length)
    end
  end

  defp read_operand(input, offset, length) do
    input
    |> slice_with_right_padding(offset, length)
    |> :binary.decode_unsigned()
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
