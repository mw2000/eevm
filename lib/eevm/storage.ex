defmodule EEVM.Storage do
  @moduledoc """
  Persistent key-value storage for a single contract account: a mapping from
  256-bit slot keys to 256-bit values.

  Uninitialized slots return `0`. All values are masked to 256 bits on write.
  """

  @type t :: %__MODULE__{
          slots: %{non_neg_integer() => non_neg_integer()}
        }

  defstruct slots: %{}

  @doc "Creates a new empty storage."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates storage pre-loaded with initial slot values.

  Useful for testing or simulating contract state.

  ## Example

      iex> storage = EEVM.Storage.new(%{0 => 42, 1 => 100})
      iex> EEVM.Storage.load(storage, 0)
      42
  """
  @spec new(%{non_neg_integer() => non_neg_integer()}) :: t()
  def new(initial) when is_map(initial) do
    %__MODULE__{slots: initial}
  end

  @doc """
  Loads a value from a storage slot.

  Returns 0 for uninitialized slots — the EVM treats all 2^256 slots as
  existing with a default value of 0.

  ## Example

      iex> storage = EEVM.Storage.new()
      iex> EEVM.Storage.load(storage, 42)
      0
  """
  @spec load(t(), non_neg_integer()) :: non_neg_integer()
  def load(%__MODULE__{slots: slots}, key) do
    Map.get(slots, key, 0)
  end

  @doc """
  Stores a value into a storage slot.

  Returns the updated storage. Writing 0 to a slot is valid and keeps the
  key in the map (in a production EVM, this could trigger a gas refund).

  ## Example

      iex> storage = EEVM.Storage.new() |> EEVM.Storage.store(0, 42)
      iex> EEVM.Storage.load(storage, 0)
      42
  """
  @spec store(t(), non_neg_integer(), non_neg_integer()) :: t()
  def store(%__MODULE__{slots: slots}, key, value) do
    %__MODULE__{slots: Map.put(slots, key, band_256(value))}
  end

  @doc """
  Returns the storage contents as a map for inspection.
  """
  @spec to_map(t()) :: %{non_neg_integer() => non_neg_integer()}
  def to_map(%__MODULE__{slots: slots}), do: slots

  # Masks to 256 bits — all EVM values are uint256.
  defp band_256(value) do
    import Bitwise
    Bitwise.band(value, (1 <<< 256) - 1)
  end
end
