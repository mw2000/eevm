defmodule EEVM.WorldState do
  @moduledoc """
  Minimal world/account state used for external account lookups.

  ## EVM Concepts

  The EVM distinguishes between the current execution frame and global account state.
  `EEVM.MachineState` stores frame-local execution data (pc, stack, memory), while
  this module stores account-level data used by external inspection opcodes:

  - `EXTCODESIZE` (0x3B)
  - `EXTCODECOPY` (0x3C)
  - `EXTCODEHASH` (0x3F)

  The state is intentionally minimal for this learning implementation. Each account
  can include `:balance`, `:nonce`, `:code`, and `:storage`. Missing accounts behave
  like non-existent EVM accounts: no code and zero balance.

  ## Elixir Learning Notes

  - The world state is represented as a struct wrapping a map keyed by numeric
    addresses.
  - Optional map keys let account records stay lightweight while preserving a
    clear shape via typespecs.
  - `Map.get/3` gives spec-friendly defaults (`<<>>` for code, `0` for balance)
    without introducing special sentinel values.
  """

  alias EEVM.Storage

  @type account :: %{
          optional(:balance) => non_neg_integer(),
          optional(:nonce) => non_neg_integer(),
          optional(:code) => binary(),
          optional(:storage) => Storage.t()
        }

  @type t :: %__MODULE__{accounts: %{non_neg_integer() => account()}}

  defstruct accounts: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new(%{optional(non_neg_integer()) => account()}) :: t()
  def new(accounts) when is_map(accounts), do: %__MODULE__{accounts: accounts}

  @spec get_account(t(), non_neg_integer()) :: account() | nil
  def get_account(%__MODULE__{accounts: accounts}, address), do: Map.get(accounts, address)

  @spec account_exists?(t(), non_neg_integer()) :: boolean()
  def account_exists?(%__MODULE__{accounts: accounts}, address), do: Map.has_key?(accounts, address)

  @spec get_code(t(), non_neg_integer()) :: binary()
  def get_code(world_state, address) do
    case get_account(world_state, address) do
      nil -> <<>>
      account -> Map.get(account, :code, <<>>)
    end
  end

  @spec get_balance(t(), non_neg_integer()) :: non_neg_integer()
  def get_balance(world_state, address) do
    case get_account(world_state, address) do
      nil -> 0
      account -> Map.get(account, :balance, 0)
    end
  end
end
