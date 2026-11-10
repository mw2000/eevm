defmodule EEVM.Precompiles.ModExp do
  @moduledoc """
  Modular exponentiation precompile — address `0x05` (EIP-198).

  Computes `base^exp mod modulus` over arbitrarily large integers.

  ### Gas schedule (EIP-198, Byzantium through Istanbul)

  `gas = floor(multiplication_complexity * iteration_count / 20)`

  where `multiplication_complexity` of `x = max(base_length, mod_length)` is
  `x^2` for `x <= 64`, `x^2 / 4 + 96x - 3072` for `x <= 1024`, and
  `x^2 / 16 + 480x - 199680` above, and `iteration_count` is computed as for
  EIP-2565 below.

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

  ### Input bounds (EIP-7823, Osaka onward)

  If `base_length`, `exp_length`, or `mod_length` exceeds 1024 bytes, the call
  fails with `{:error, :invalid_input}`, consuming all gas it was given.

  `execute/3` picks the gas schedule and bounds from the hardfork it is given.

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

  alias EEVM.HardforkConfig

  # EIP-7823: maximum base, exponent, and modulus length in bytes.
  @max_input_length 1024

  @doc """
  Executes the ModExp precompile with the gas schedule and input bounds of
  `hardfork` (default: Cancun).
  """
  @spec execute(binary(), non_neg_integer(), HardforkConfig.t()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :out_of_gas | :invalid_input}
  def execute(input, gas_limit, hardfork \\ HardforkConfig.new(:cancun)) do
    <<base_length::unsigned-size(256), exp_length::unsigned-size(256),
      mod_length::unsigned-size(256)>> = slice_with_right_padding(input, 0, 96)

    if HardforkConfig.enabled?(hardfork, :eip_7823) and
         max(base_length, max(exp_length, mod_length)) > @max_input_length do
      {:error, :invalid_input}
    else
      # Gas depends only on the header and the exponent's first 32 bytes, so
      # charge it before touching operands whose declared lengths may be huge.
      exp_head = exponent_head(input, base_length, exp_length)
      cost = gas_cost(pricing(hardfork), base_length, exp_length, mod_length, exp_head)

      if cost > gas_limit do
        {:error, :out_of_gas}
      else
        {:ok, modexp(input, base_length, exp_length, mod_length), cost}
      end
    end
  end

  defp exponent_head(input, base_length, exp_length) do
    input
    |> slice_with_right_padding(96 + base_length, min(exp_length, 32))
    |> :binary.decode_unsigned()
  end

  defp pricing(hardfork) do
    cond do
      HardforkConfig.enabled?(hardfork, :eip_7883) -> :eip_7883
      HardforkConfig.enabled?(hardfork, :eip_2565) -> :eip_2565
      true -> :eip_198
    end
  end

  defp gas_cost(:eip_198, base_length, exp_length, mod_length, exp_head) do
    multiplication_complexity = eip_198_complexity(max(base_length, mod_length))
    div(multiplication_complexity * iteration_count(exp_length, exp_head, 8), 20)
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

  defp eip_198_complexity(x) when x <= 64, do: square(x)
  defp eip_198_complexity(x) when x <= 1024, do: div(square(x), 4) + 96 * x - 3072
  defp eip_198_complexity(x), do: div(square(x), 16) + 480 * x - 199_680

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
      result = mod_pow(base, exponent, modulus)
      left_pad(:binary.encode_unsigned(result), mod_length)
    end
  end

  # base^exponent mod modulus, for modulus >= 1, by fixed-window
  # square-and-multiply: the exponent is read in w-bit digits, each digit
  # costs w squarings and one multiplication by a precomputed base^digit, and
  # every product is reduced with `rem/2`. On the BEAM this beats Montgomery
  # and Barrett reduction, whose extra products cost more than the bignum
  # division `rem/2` does, and it costs the same for odd and even moduli.
  defp mod_pow(_base, _exponent, 1), do: 0

  defp mod_pow(base, exponent, modulus) do
    base = rem(base, modulus)
    width = window_width(exponent)
    table = base_powers(base, Bitwise.bsl(1, width), modulus)

    exponent
    |> Integer.digits(Bitwise.bsl(1, width))
    |> Enum.reduce(1, fn digit, acc ->
      acc = square_times(acc, width, modulus)
      if digit == 0, do: acc, else: rem(acc * elem(table, digit), modulus)
    end)
  end

  # Wider windows save multiplications but cost 2^w − 2 to build the table,
  # so small exponents (3, 65537) use plain binary. These are OpenSSL's
  # thresholds (`BN_window_bits_for_exponent_size`).
  defp window_width(exponent) do
    case bit_size(:binary.encode_unsigned(exponent)) do
      bits when bits > 671 -> 6
      bits when bits > 239 -> 5
      bits when bits > 79 -> 4
      bits when bits > 23 -> 3
      _bits -> 1
    end
  end

  # {base^0, base^1, ..., base^(count − 1)} mod modulus.
  defp base_powers(base, count, modulus) do
    1..(count - 1)//1
    |> Enum.scan(1, fn _, power -> rem(power * base, modulus) end)
    |> then(&List.to_tuple([1 | &1]))
  end

  defp square_times(value, 0, _modulus), do: value

  defp square_times(value, n, modulus),
    do: square_times(rem(value * value, modulus), n - 1, modulus)

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
