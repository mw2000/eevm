defmodule EEVM.Error do
  @moduledoc """
  Reference for all error atoms used across the EEVM codebase.

  EEVM uses tagged tuples for error handling: `{:error, reason}` or
  `{:error, reason, state}`. This module documents every error reason atom
  and which modules produce them.

  ## Execution Errors

  These errors halt the current execution frame:

  | Error | Source | Meaning |
  |-------|--------|---------|
  | `:stack_underflow` | `EEVM.Interpreter` (pre-dispatch check), `EEVM.Interpreter.Stack` | Attempted to pop/peek from an empty stack |
  | `:stack_overflow` | `EEVM.Interpreter` (pre-dispatch check), `EEVM.Interpreter.Stack` | Attempted to push onto a full stack (1,024 elements) |
  | `:out_of_gas` | `EEVM.Interpreter.MachineState` | Gas consumed exceeds available gas |
  | `:invalid_jump_destination` | `EEVM.Interpreter.Instructions.ControlFlow` | JUMP/JUMPI target is not a JUMPDEST |
  | `:static_state_modification` | `EEVM.Interpreter`, `EEVM.Interpreter.Instructions.System.Calls` | State-mutating opcode or value-bearing CALL inside a STATICCALL frame (EIP-214) |
  | `:return_data_out_of_bounds` | `EEVM.Interpreter.Instructions.Environment.Data` | RETURNDATACOPY reads past the end of the return data buffer |
  | `:initcode_too_large` | `EEVM.Interpreter.Instructions.System.Creation` | CREATE/CREATE2 initcode exceeds 49,152 bytes (EIP-3860) |
  | `:insufficient_balance` | `EEVM.WorldState` | Transfer amount exceeds account balance |

  ## Precompile Errors

  Returned by precompiled contract implementations:

  | Error | Source | Meaning |
  |-------|--------|---------|
  | `:out_of_gas` | All precompiles | Gas limit insufficient for the operation |
  | `:invalid_input` | BN256, Blake2F, KZG, ModExp (EIP-7823) | Input data has wrong length or format |
  | `:invalid_point` | BN256 | Elliptic curve point not on the alt_bn128 curve |
  | `:invalid_versioned_hash` | KZG | Versioned hash doesn't match expected format |
  | `:invalid_field_element` | KZG | Field element is not in the valid range |
  | `:proof_verification_failed` | KZG | KZG proof verification returned false |
  | `:not_implemented` | `EEVM.Precompiles` | Precompile address has no implementation |

  ## Transaction Validation Errors

  Returned by `EEVM.Transaction.Validator.validate/4` (and so by
  `EEVM.Handler.execute/4`) before any state changes. Checks run in the order
  listed and the first failure wins.

  | Error | Meaning |
  |-------|---------|
  | `:tx_type_not_supported` | Set-code (type 4) transaction before Prague (EIP-7702) |
  | `:set_code_tx_no_creation` | Set-code transaction has no `to` address (EIP-7702) |
  | `:empty_authorization_list` | Set-code transaction carries no authorizations (EIP-7702) |
  | `:invalid_authorization` | An authorization field is out of range, such as a nonce of 2^64 or more (EIP-7702) |
  | `:intrinsic_gas_too_low` | `gas_limit` is below the intrinsic gas (or, from Prague, the EIP-7623 calldata floor) |
  | `:gas_limit_exceeds_cap` | `gas_limit` is above 2^24 (EIP-7825, from Osaka) |
  | `:gas_limit_exceeds_block` | `gas_limit` is above the block gas limit |
  | `:nonce_too_low` | `nonce` is below the sender's account nonce |
  | `:nonce_too_high` | `nonce` is above the sender's account nonce |
  | `:nonce_is_max` | `nonce` is 2^64 - 1, so the sender's nonce can't be incremented (EIP-2681) |
  | `:priority_fee_above_max_fee` | `max_priority_fee_per_gas` exceeds `max_fee_per_gas` (EIP-1559) |
  | `:max_fee_below_basefee` | `max_fee_per_gas` is below the block base fee (EIP-1559) |
  | `:insufficient_balance` | Balance can't cover `gas_limit * max price + blob gas * max_fee_per_blob_gas + value` |
  | `:sender_not_eoa` | Sender has code other than a delegation designator (EIP-3607, EIP-7702) |
  | `:blob_tx_no_creation` | Blob transaction has no `to` address (EIP-4844) |
  | `:no_blob_data` | Blob transaction carries no blob hashes (EIP-4844) |
  | `:blob_fee_too_low` | `max_fee_per_blob_gas` is below the block blob base fee (EIP-4844) |
  | `:initcode_too_large` | Contract-creation data exceeds 49,152 bytes (EIP-3860) |

  ## Block Header Validation Errors

  Returned by `EEVM.Block.HeaderValidator.validate/3` when a header is not a
  valid successor of its parent. Checks run in the order listed and the first
  failure wins.

  | Error | Meaning |
  |-------|---------|
  | `:unknown_parent` | `parent_hash` doesn't match the parent header's hash |
  | `:invalid_block_number` | `number` isn't the parent's number plus one |
  | `:invalid_timestamp` | `timestamp` isn't greater than the parent's |
  | `:extra_data_too_big` | `extra_data` is longer than 32 bytes |
  | `:invalid_gas_limit` | `gas_limit` is below 5,000 or moves by `parent_gas_limit / 1024` or more |
  | `:gas_limit_too_big` | `gas_limit` exceeds the signed 64-bit maximum |
  | `:invalid_base_fee` | `base_fee_per_gas` differs from the value derived from the parent (EIP-1559, from London) |
  | `:invalid_difficulty` | `difficulty` isn't 0 (EIP-3675, from Paris) |
  | `:invalid_nonce` | `nonce` isn't eight zero bytes (EIP-3675, from Paris) |
  | `:invalid_ommers_hash` | `ommers_hash` isn't the empty-list hash (EIP-3675, from Paris) |
  | `:missing_header_fields` | A field the fork defines (`base_fee_per_gas`, `withdrawals_root`, the blob fields, `parent_beacon_block_root`, `requests_hash`) is `nil` |
  | `:unexpected_header_fields` | A field from a later fork is set |
  | `:invalid_blob_gas_used` | `blob_gas_used` isn't a multiple of 131,072 or exceeds the fork's per-block maximum (EIP-4844, EIP-7691) |
  | `:invalid_excess_blob_gas` | `excess_blob_gas` differs from the value derived from the parent (EIP-4844, EIP-7918 from Osaka) |

  ## Block Errors

  Returned by `EEVM.Block.decode/1`, `validate/3`, `execute/4`, and
  `build/4`, in addition to every header validation error above.

  | Error | Meaning |
  |-------|---------|
  | `:invalid_block_encoding` | The bytes aren't a canonical RLP block |
  | `:rlp_block_size_exceeded` | The encoded block is over 8,388,608 bytes (EIP-7934, from Osaka) |
  | `:invalid_transactions_root` | `transactions_root` doesn't commit to the block's transactions |
  | `:invalid_withdrawals_root` | `withdrawals_root` doesn't commit to the withdrawals, or withdrawals are present before Shanghai or missing after |
  | `:invalid_ommers_hash` | `ommers_hash` doesn't commit to the block's ommers |
  | `:invalid_blob_gas_used` | `blob_gas_used` differs from the transactions' total blob gas |
  | `{:tx_failed, index, reason}` | Transaction `index` (0-based) was rejected: `reason` is an `EEVM.Handler` error, or `:gas_allowance_exceeded` when its gas limit exceeds the gas left in the block |
  | `:invalid_gas_used` | `gas_used` differs from the gas the transactions used |
  | `:invalid_logs_bloom` | `logs_bloom` differs from the receipts' combined bloom |
  | `:invalid_receipts_root` | `receipts_root` differs from the receipts' root |
  | `:invalid_state_root` | `state_root` differs from the post-block state |
  | `:invalid_deposit_event_layout` | A deposit contract `DepositEvent` log isn't the 576-byte EIP-6110 layout (from Prague) |
  | `:system_contract_empty` | The EIP-7002 or EIP-7251 request contract has no code (from Prague) |
  | `:system_contract_call_failed` | The end-of-block call to the EIP-7002 or EIP-7251 request contract failed (from Prague) |
  | `:invalid_requests_hash` | `requests_hash` differs from the EIP-7685 hash of the block's requests (from Prague) |

  ## Registry Errors

  | Error | Source | Meaning |
  |-------|--------|---------|
  | `:unknown_opcode` | `EEVM.Interpreter.Instructions.Registry` | Opcode byte has no known metadata |

  ## Machine State Status Values

  The `MachineState.status` field uses these atoms (not errors, but related):

  - `:running` — execution in progress
  - `:stopped` — normal termination (STOP or RETURN)
  - `:reverted` — controlled failure (REVERT)
  - `:invalid` — INVALID opcode or unknown opcode executed
  - `:out_of_gas` — gas exhausted
  - `{:error, reason}` — wrapped error from opcode execution
  """

  @type execution_error ::
          :stack_underflow
          | :stack_overflow
          | :out_of_gas
          | :invalid_jump_destination
          | :static_state_modification
          | :return_data_out_of_bounds
          | :initcode_too_large
          | :insufficient_balance

  @type precompile_error ::
          :out_of_gas
          | :invalid_input
          | :invalid_point
          | :invalid_versioned_hash
          | :invalid_field_element
          | :proof_verification_failed
          | :not_implemented

  @type transaction_validation_error ::
          :tx_type_not_supported
          | :set_code_tx_no_creation
          | :empty_authorization_list
          | :invalid_authorization
          | :intrinsic_gas_too_low
          | :gas_limit_exceeds_cap
          | :gas_limit_exceeds_block
          | :nonce_too_low
          | :nonce_too_high
          | :nonce_is_max
          | :priority_fee_above_max_fee
          | :max_fee_below_basefee
          | :insufficient_balance
          | :sender_not_eoa
          | :blob_tx_no_creation
          | :no_blob_data
          | :blob_fee_too_low
          | :initcode_too_large

  @type header_validation_error ::
          :unknown_parent
          | :invalid_block_number
          | :invalid_timestamp
          | :extra_data_too_big
          | :invalid_gas_limit
          | :gas_limit_too_big
          | :invalid_base_fee
          | :invalid_difficulty
          | :invalid_nonce
          | :invalid_ommers_hash
          | :missing_header_fields
          | :unexpected_header_fields
          | :invalid_blob_gas_used
          | :invalid_excess_blob_gas

  @type block_error ::
          :invalid_block_encoding
          | :rlp_block_size_exceeded
          | header_validation_error()
          | :invalid_transactions_root
          | :invalid_withdrawals_root
          | :invalid_blob_gas_used
          | {:tx_failed, non_neg_integer(), atom()}
          | :invalid_gas_used
          | :invalid_logs_bloom
          | :invalid_receipts_root
          | :invalid_state_root
          | :invalid_deposit_event_layout
          | :system_contract_empty
          | :system_contract_call_failed
          | :invalid_requests_hash

  @type reason ::
          execution_error()
          | precompile_error()
          | :unknown_opcode
          | transaction_validation_error()
          | block_error()
end
