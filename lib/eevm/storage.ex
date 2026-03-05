defmodule EEVM.Storage do
  @moduledoc """
  Persistent key-value storage for the EVM.

  ## EVM Concepts

  Storage is the EVM's persistent state — it survives across transactions and
  blocks. Each contract (account) has its own isolated storage, a mapping from
  256-bit keys ("slots") to 256-bit values.

  This is what makes Ethereum a *stateful* computer. When a Solidity contract
  declares `uint256 public counter`, that variable lives in storage slot 0.
  `SSTORE` writes to it, `SLOAD` reads from it.

  ### Storage vs Memory

  | Property | Storage | Memory |
  |----------|---------|--------|
  | Lifetime | Permanent (on-chain) | Cleared after each call |
  | Cost | Very expensive (20,000 gas to write) | Cheap (3 gas + expansion) |
  | Size | 2^256 slots per account | Grows dynamically |
  | Access | Key-value (slot → value) | Byte-addressable (offset → byte) |

  ### Gas Costs (Simplified)

  In a production EVM, storage gas depends on cold/warm access (EIP-2929) and
  whether you're writing to a fresh vs dirty slot (EIP-2200). We use simplified
  flat costs for learning:

  - `SLOAD`: 200 gas (warm access cost)
  - `SSTORE`: 20,000 gas (fresh write cost)

  The full EIP-2929 + EIP-2200 model tracks an "access set" per transaction and
  distinguishes between original, current, and new values to compute refunds.

  ## Elixir Learning Notes

  - We use a plain `Map` as the underlying data structure. Elixir maps have
    O(log n) access which is fine for our learning purposes.
  - Uninitialized slots return 0 — we use `Map.get/3` with a default value
    rather than checking for key existence.
  - The module is purely functional: `store/3` returns a new storage, it doesn't
    mutate the old one. This is a core Elixir/functional programming pattern.
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
