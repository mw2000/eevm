defmodule EEVM.Storage do
  @moduledoc """
  Per-account persistent SLOAD/SSTORE store: a `slot => value` map of 256-bit
  keys to 256-bit values. Uninitialized slots read as 0; stored values are
  masked to uint256.

  Gas accounting (cold/warm under EIP-2929, original/current/new under
  EIP-2200, refunds) lives in `EEVM.Gas.Dynamic` and the SSTORE handler —
  this module is just the data store.
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

      iex> storage = EEVM.Storage.new(%{0 => 42, 1 => 100})
      iex> EEVM.Storage.load(storage, 0)
      42
  """
  @spec new(%{non_neg_integer() => non_neg_integer()}) :: t()
  def new(initial) when is_map(initial) do
    %__MODULE__{slots: initial}
  end

  @doc """
  Loads `key`. Uninitialized slots return 0.

      iex> storage = EEVM.Storage.new()
      iex> EEVM.Storage.load(storage, 42)
      0
  """
  @spec load(t(), non_neg_integer()) :: non_neg_integer()
  def load(%__MODULE__{slots: slots}, key) do
    Map.get(slots, key, 0)
  end

  @doc """
  Stores `value` (masked to uint256) at `key`. Writing 0 keeps the key in
  the map; refund accounting is handled by the SSTORE gas handler.

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

  defp band_256(value) do
    import Bitwise
    Bitwise.band(value, (1 <<< 256) - 1)
  end
end
