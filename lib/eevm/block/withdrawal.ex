defmodule EEVM.Block.Withdrawal do
  @moduledoc """
  EIP-4895 beacon-chain withdrawal: a credit applied to an execution-layer
  account at the start of a block.

  | Field | Description |
  |-------|-------------|
  | `index` | The withdrawal's index, counting every withdrawal since Shanghai |
  | `validator_index` | Index of the validator withdrawing |
  | `address` | Execution-layer address credited |
  | `amount` | Amount in **gwei** |

  The wire `amount` is denominated in gwei; the EVM works in wei, so the
  balance bump is `amount * 1_000_000_000`. Withdrawals are applied between
  the transactions and the state-root commitment.
  """

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          validator_index: non_neg_integer(),
          address: non_neg_integer(),
          amount: non_neg_integer()
        }

  defstruct index: 0, validator_index: 0, address: 0, amount: 0
end
