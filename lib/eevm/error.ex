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
  | `:stack_underflow` | `EEVM.Interpreter.Stack` | Attempted to pop/peek from an empty stack |
  | `:stack_overflow` | `EEVM.Interpreter.Stack` | Attempted to push onto a full stack (1,024 elements) |
  | `:out_of_gas` | `EEVM.Interpreter.MachineState` | Gas consumed exceeds available gas |
  | `:invalid_jump_destination` | `EEVM.Interpreter.Instructions.ControlFlow` | JUMP/JUMPI target is not a JUMPDEST |
  | `:return_data_out_of_bounds` | `EEVM.Interpreter.Instructions.Environment.Data` | RETURNDATACOPY reads past the end of the return data buffer |
  | `:insufficient_balance` | `EEVM.WorldState` | Transfer amount exceeds account balance |
  | `:max_call_depth` | `EEVM.Interpreter.MachineState` | Nested call depth exceeds 1,024 |
  | `:empty_call_stack` | `EEVM.Interpreter.MachineState` | Attempted to pop a frame with no frames on stack |

  ## Precompile Errors

  Returned by precompiled contract implementations:

  | Error | Source | Meaning |
  |-------|--------|---------|
  | `:out_of_gas` | All precompiles | Gas limit insufficient for the operation |
  | `:invalid_input` | BN256, Blake2F, KZG | Input data has wrong length or format |
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
  | `:intrinsic_gas_too_low` | `gas_limit` is below the intrinsic gas (or, from Prague, the EIP-7623 calldata floor) |
  | `:gas_limit_exceeds_cap` | `gas_limit` is above 2^24 (EIP-7825, from Osaka) |
  | `:gas_limit_exceeds_block` | `gas_limit` is above the block gas limit |
  | `:nonce_too_low` | `nonce` is below the sender's account nonce |
  | `:nonce_too_high` | `nonce` is above the sender's account nonce |
  | `:priority_fee_above_max_fee` | `max_priority_fee_per_gas` exceeds `max_fee_per_gas` (EIP-1559) |
  | `:max_fee_below_basefee` | `max_fee_per_gas` is below the block base fee (EIP-1559) |
  | `:insufficient_balance` | Balance can't cover `gas_limit * max price + blob gas * max_fee_per_blob_gas + value` |
  | `:sender_not_eoa` | Sender has code (EIP-3607) |
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
  | `:invalid_excess_blob_gas` | `excess_blob_gas` differs from the value derived from the parent (EIP-4844, EIP-7918 from Osaka) |

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
          | :return_data_out_of_bounds
          | :insufficient_balance
          | :max_call_depth
          | :empty_call_stack

  @type precompile_error ::
          :out_of_gas
          | :invalid_input
          | :invalid_point
          | :invalid_versioned_hash
          | :invalid_field_element
          | :proof_verification_failed
          | :not_implemented

  @type transaction_validation_error ::
          :intrinsic_gas_too_low
          | :gas_limit_exceeds_cap
          | :gas_limit_exceeds_block
          | :nonce_too_low
          | :nonce_too_high
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
          | :invalid_excess_blob_gas

  @type reason ::
          execution_error()
          | precompile_error()
          | :unknown_opcode
          | transaction_validation_error()
          | header_validation_error()
end
