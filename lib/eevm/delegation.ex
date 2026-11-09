defmodule EEVM.Delegation do
  @moduledoc """
  EIP-7702 delegation designators.

  A set-code transaction writes `0xef0100 || address` as an authority's code.
  From then on, calls to the authority (top-level and CALL, CALLCODE,
  DELEGATECALL, STATICCALL) execute the code stored at `address`, while
  EXTCODESIZE, EXTCODECOPY, and EXTCODEHASH still see the 23-byte designator.
  Only one hop is followed: a designator that points at another designator
  runs that designator as code.
  """

  @marker <<0xEF, 0x01, 0x00>>

  @doc """
  Build the designator code for `address`.

  ## Example

      iex> EEVM.Delegation.designator(0x1234)
      <<0xEF, 0x01, 0x00, 0::144, 0x12, 0x34>>
  """
  @spec designator(non_neg_integer()) :: binary()
  def designator(address), do: <<@marker::binary, address::unsigned-big-160>>

  @doc """
  Return the delegate address if `code` is exactly a delegation designator.

  ## Examples

      iex> EEVM.Delegation.delegated_address(EEVM.Delegation.designator(0xBEEF))
      {:ok, 0xBEEF}

      iex> EEVM.Delegation.delegated_address(<<0x60, 0x00>>)
      :error
  """
  @spec delegated_address(binary()) :: {:ok, non_neg_integer()} | :error
  def delegated_address(<<0xEF, 0x01, 0x00, address::unsigned-big-160>>), do: {:ok, address}
  def delegated_address(_code), do: :error

  @doc "Return whether `code` is exactly a delegation designator."
  @spec designator?(binary()) :: boolean()
  def designator?(code), do: delegated_address(code) != :error
end
