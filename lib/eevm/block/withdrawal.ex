defmodule EEVM.Block.Withdrawal do
  @moduledoc """
  EIP-4895 beacon-chain withdrawal: a credit applied to an execution-layer
  account at the start of a block.

  ## EVM Concepts

  Validators on the beacon chain accumulate rewards (and partial-stake exits)
  that periodically need to land on the execution layer as plain balance
  increases. The consensus layer hands the execution client a flat list of
  these credits per block. They are not transactions: there is no signature,
  no gas, no nonce, and no possibility of failure. The execution client
  simply iterates the list and adds each `amount` to `address`.

  Per EIP-4895 the wire `amount` is denominated in *gwei*; the EVM works in
  wei everywhere else, so the actual balance bump is `amount * 1_000_000_000`.

  Withdrawals are folded into block processing alongside transactions: the
  state root the header advertises is post-withdrawals.
  """

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          validator_index: non_neg_integer(),
          address: non_neg_integer(),
          amount: non_neg_integer()
        }

  defstruct index: 0, validator_index: 0, address: 0, amount: 0
end
