defmodule EEVM.StateChanges do
  @moduledoc """
  The state a transaction, block, or call wrote, as a backend's
  `c:EEVM.Database.commit/2` receives it and results carry it in `changes`.

  `accounts` maps each written address to either `:destroyed`, when the
  account no longer exists, or its new state:

  | Key | Description |
  |-----|-------------|
  | `balance`, `nonce` | The account's new balance and nonce |
  | `code_hash` | keccak256 of its code |
  | `code` | The code when the backend may not have it yet, else `nil` |
  | `storage` | The written slots, `%{slot => value}`; a value of 0 clears the slot |
  | `destroyed?` | The account and all its storage were deleted first, so apply `storage` to an empty store |

  Apply each address independently: for `:destroyed`, delete the account and
  its storage; otherwise clear its storage if `destroyed?`, write the account
  fields, store `code` under `code_hash` when it is set, and apply `storage`.
  """

  @type account_change :: %{
          balance: non_neg_integer(),
          nonce: non_neg_integer(),
          code_hash: <<_::256>>,
          code: binary() | nil,
          storage: %{non_neg_integer() => non_neg_integer()},
          destroyed?: boolean()
        }

  @type t :: %__MODULE__{accounts: %{non_neg_integer() => account_change() | :destroyed}}

  defstruct accounts: %{}
end
