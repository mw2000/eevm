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

  # base^exponent mod modulus, for modulus >= 1.
  #
  # `:crypto.mod_pow/3` is OpenSSL's BN_mod_exp, which uses Montgomery
  # multiplication only for odd moduli; even ones take a reciprocal-based path
  # that is 3-4x slower (2048-bit operands: 2.1 ms odd, 6.8 ms even). Gas does
  # not depend on parity, so for an even modulus m = q·2^k (q odd) this
  # computes the result mod q with OpenSSL and mod 2^k with bit masks, then
  # recombines them by CRT. When 2^k is most of the modulus, the masked part
  # (k squarings of k-bit numbers) costs more than OpenSSL's even path, so the
  # split applies only while k is at most half the modulus's bit length.
  defp mod_pow(base, exponent, modulus) do
    k = trailing_zero_bits(modulus, 0)

    if k == 0 or 2 * k > highest_bit_index(modulus) + 1 do
      crypto_mod_pow(base, exponent, modulus)
    else
      q = Bitwise.bsr(modulus, k)
      mask = Bitwise.bsl(1, k) - 1
      mod_q = if q == 1, do: 0, else: crypto_mod_pow(base, exponent, q)
      mod_2k = pow_mod_2k(Bitwise.band(base, mask), exponent, k, mask)

      # Garner: x = mod_q + q·t with t = (mod_2k − mod_q)·q⁻¹ mod 2^k, so
      # x ≡ mod_q (mod q), x ≡ mod_2k (mod 2^k), and 0 <= x < q·2^k.
      t = Bitwise.band((mod_2k - mod_q) * inverse_mod_2k(q, k, mask), mask)
      mod_q + q * t
    end
  end

  defp crypto_mod_pow(base, exponent, modulus) do
    base |> :crypto.mod_pow(exponent, modulus) |> :binary.decode_unsigned()
  end

  defp trailing_zero_bits(value, count) when rem(value, 2) == 1, do: count
  defp trailing_zero_bits(value, count), do: trailing_zero_bits(Bitwise.bsr(value, 1), count + 1)

  # base^exponent mod 2^k, for base < 2^k and k >= 1. Odd bases form the group
  # (Z/2^k)*, whose exponent is 2^(k−2) for k >= 3 (1 for k = 1, 2 for k = 2),
  # so the exponent can be reduced modulo it. An even base contributes at
  # least one factor of 2 per multiplication, so base^exponent ≡ 0 once
  # exponent >= k; below that the exponent is small. Note 0^0 = 1.
  defp pow_mod_2k(base, exponent, k, mask) when rem(base, 2) == 1 do
    group_exponent = if k >= 3, do: Bitwise.bsl(1, k - 2), else: Bitwise.bsl(1, k - 1)
    pow_masked(base, Bitwise.band(exponent, group_exponent - 1), mask)
  end

  defp pow_mod_2k(_base, exponent, k, _mask) when exponent >= k, do: 0
  defp pow_mod_2k(base, exponent, _k, mask), do: pow_masked(base, exponent, mask)

  defp pow_masked(base, exponent, mask) do
    exponent
    |> Integer.digits(2)
    |> Enum.reduce(Bitwise.band(1, mask), fn bit, acc ->
      acc = Bitwise.band(acc * acc, mask)
      if bit == 1, do: Bitwise.band(acc * base, mask), else: acc
    end)
  end

  # q⁻¹ mod 2^k for odd q by Newton iteration: q is its own inverse mod 8, and
  # x ← x·(2 − q·x) doubles the number of correct low bits each step (about
  # 10x faster than `Integer.extended_gcd/2` for 2048-bit q).
  defp inverse_mod_2k(q, k, mask) do
    {inverse, _bits} =
      {q, 3}
      |> Stream.iterate(fn {x, bits} -> {Bitwise.band(x * (2 - q * x), mask), 2 * bits} end)
      |> Enum.find(fn {_x, bits} -> bits >= k end)

    Bitwise.band(inverse, mask)
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
