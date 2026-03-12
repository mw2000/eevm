defmodule EEVM.Opcodes do
  @moduledoc """
  Public opcode metadata API.

  Backwards-compatible facade over `EEVM.Opcodes.Registry`.
  """

  alias EEVM.Opcodes.Registry

  @spec info(non_neg_integer()) :: {:ok, map()} | {:error, :unknown_opcode}
  defdelegate info(op), to: Registry

  @spec is_push?(non_neg_integer()) :: boolean()
  defdelegate is_push?(op), to: Registry

  @spec push_bytes(non_neg_integer()) :: non_neg_integer()
  defdelegate push_bytes(op), to: Registry

  @spec is_dup?(non_neg_integer()) :: boolean()
  defdelegate is_dup?(op), to: Registry

  @spec is_swap?(non_neg_integer()) :: boolean()
  defdelegate is_swap?(op), to: Registry
end
