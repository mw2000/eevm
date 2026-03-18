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
  | `:stack_underflow` | `EEVM.Stack` | Attempted to pop/peek from an empty stack |
  | `:stack_overflow` | `EEVM.Stack` | Attempted to push onto a full stack (1,024 elements) |
  | `:out_of_gas` | `EEVM.MachineState` | Gas consumed exceeds available gas |
  | `:invalid_jump_destination` | `EEVM.Opcodes.ControlFlow` | JUMP/JUMPI target is not a JUMPDEST |
  | `:insufficient_balance` | `EEVM.WorldState` | Transfer amount exceeds account balance |
  | `:max_call_depth` | `EEVM.MachineState` | Nested call depth exceeds 1,024 |
  | `:empty_call_stack` | `EEVM.MachineState` | Attempted to pop a frame with no frames on stack |

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

  ## Registry Errors

  | Error | Source | Meaning |
  |-------|--------|---------|
  | `:unknown_opcode` | `EEVM.Opcodes.Registry` | Opcode byte has no known metadata |

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

  @type reason :: execution_error() | precompile_error() | :unknown_opcode
end
