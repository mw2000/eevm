defmodule EEVM.Error do
  @moduledoc """
  Reference for all error atoms used across the EEVM codebase.

  EEVM uses tagged tuples for error handling: `{:error, reason}` or
  `{:error, reason, state}`. This module documents every error reason atom
  and which modules produce them; `t:reason/0` is their union and
  `message/1` describes one.

  Reasons are plain atoms, so they match in `case` and `with` directly. They
  are part of the public API: a new reason is a minor change, and renaming
  or removing one is a breaking change. The only composite reason is
  `{:tx_failed, index, reason}` from block execution.

  ## Execution Errors

  These errors halt the current execution frame:

  | Error | Source | Meaning |
  |-------|--------|---------|
  | `:stack_underflow` | `EEVM.Interpreter` (pre-dispatch check), `EEVM.Interpreter.Stack` | Attempted to pop/peek from an empty stack |
  | `:stack_overflow` | `EEVM.Interpreter` (pre-dispatch check), `EEVM.Interpreter.Stack` | Attempted to push onto a full stack (1,024 elements) |
  | `:out_of_gas` | `EEVM.Interpreter.MachineState` | Gas consumed exceeds available gas |
  | `:invalid_jump_destination` | `EEVM.Interpreter` | JUMP/JUMPI target is not a JUMPDEST |
  | `:static_state_modification` | `EEVM.Interpreter`, `EEVM.Interpreter.Instructions.System.Calls` | State-mutating opcode or value-bearing CALL inside a STATICCALL frame (EIP-214) |
  | `:return_data_out_of_bounds` | `EEVM.Interpreter.Instructions.Environment.Data` | RETURNDATACOPY reads past the end of the return data buffer |
  | `:initcode_too_large` | `EEVM.Interpreter.Instructions.System.Creation` | CREATE/CREATE2 initcode exceeds 49,152 bytes (EIP-3860) |
  | `:insufficient_balance` | `EEVM.Database.transfer/4` | Transfer amount exceeds account balance |
  | `:invalid_opcode` | `EEVM.Interpreter` | INVALID (0xFE) or an opcode the fork doesn't define |
  | `:create_collision` | `EEVM.Handler.Execution` | A creation transaction targets an address that already has code, a nonce, or storage (EIP-684, EIP-7610) |
  | `:code_size_limit_exceeded` | `EEVM.Handler.Execution` | Deployed code is over 24,576 bytes (EIP-170) |
  | `:invalid_code_prefix` | `EEVM.Handler.Execution` | Deployed code starts with 0xEF (EIP-3541, from London) |

  ## Precompile Errors

  Returned by precompiled contract implementations:

  | Error | Source | Meaning |
  |-------|--------|---------|
  | `:out_of_gas` | All precompiles | Gas limit insufficient for the operation |
  | `:invalid_input` | BN256, BLS12-381, Blake2F, KZG, ModExp (EIP-7823) | Input data has wrong length or format |
  | `:invalid_point` | BN256, BLS12-381 | Elliptic curve point not on the curve or not in the subgroup |
  | `:invalid_versioned_hash` | KZG | Versioned hash doesn't match expected format |
  | `:invalid_field_element` | KZG | Field element is not in the valid range |
  | `:proof_verification_failed` | KZG | KZG proof verification returned false |
  | `:not_implemented` | `EEVM.Precompiles` | Precompile address has no implementation |

  ## Transaction Decoding and Signature Errors

  Returned by `EEVM.Transaction.Envelope.decode/1` and
  `EEVM.Transaction.Signer`, and so by
  `EEVM.Handler.execute/4` when it is given raw bytes or a bad signature.

  | Error | Meaning |
  |-------|---------|
  | `:invalid_transaction_input` | The transaction is neither a transaction struct nor a binary |
  | `:empty_input` | The encoded transaction is empty |
  | `:invalid_type` | The EIP-2718 type byte isn't a known transaction type |
  | `:hex_string` | The bytes are a `0x`-prefixed hex string; decode them with `EEVM.bytes/1` |
  | `:invalid_rlp` | The payload isn't valid RLP |
  | `:invalid_rlp_integer` | An integer field has leading zero bytes (non-canonical RLP) |
  | `:invalid_fields` | The RLP list has the wrong number or shape of fields for its type |
  | `:invalid_v` | A legacy `v` is neither 27/28 nor an EIP-155 value (35 or more) |
  | `:invalid_chain_id` | The transaction was signed for another chain: a typed transaction's `chain_id`, or the chain id in an EIP-155 legacy `v`, differs from the config's |
  | `:invalid_signature` | `r`, `s`, or `y_parity` is out of range (including high `s`, EIP-2), or no key recovers |
  | `:invalid_private_key` | `EEVM.Transaction.Signer.sign/3` got a key that is zero or not below the curve order |

  ## Transaction Validation Errors

  Returned by `EEVM.transact/4` (and `EEVM.Handler.execute/4`) before any
  state changes; `EEVM.Transaction.Validator` runs the checks. They run in
  the order listed and the first failure wins.

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
  | `:max_fee_below_basefee` | `max_fee_per_gas`, or `gas_price` for legacy and EIP-2930 transactions, is below the block base fee (EIP-1559) |
  | `:insufficient_balance` | Balance can't cover `gas_limit * max price + blob gas * max_fee_per_blob_gas + value` |
  | `:sender_not_eoa` | Sender has code other than a delegation designator (EIP-3607, EIP-7702) |
  | `:blob_tx_no_creation` | Blob transaction has no `to` address (EIP-4844) |
  | `:no_blob_data` | Blob transaction carries no blob hashes (EIP-4844) |
  | `:too_many_blobs` | Blob transaction carries more blobs than a block allows (EIP-4844), or more than 6 (EIP-7594) |
  | `:invalid_versioned_hash` | A blob versioned hash doesn't start with `0x01` (EIP-4844) |
  | `:blob_fee_too_low` | `max_fee_per_blob_gas` is below the block blob base fee (EIP-4844) |
  | `:initcode_too_large` | Contract-creation data exceeds 49,152 bytes (EIP-3860) |
  | `:effective_gas_price_below_basefee` | The effective gas price is below the block base fee (checked again when charging the sender) |

  ## Block Header Validation Errors

  Returned by `EEVM.Block.validate/3`, `execute/4`, and `build/4` when a
  header is not a valid successor of its parent; `EEVM.Block.HeaderValidator`
  runs the checks. They run in the order listed and the first failure wins.

  | Error | Meaning |
  |-------|---------|
  | `:unknown_parent` | `parent_hash` doesn't match the parent header's hash |
  | `:invalid_block_number` | `number` isn't the parent's number plus one |
  | `:invalid_timestamp` | `timestamp` isn't greater than the parent's |
  | `:extra_data_too_big` | `extra_data` is longer than 32 bytes |
  | `:invalid_gas_limit` | `gas_limit` is below 5,000 or moves by `parent_gas_limit / 1024` or more |
  | `:gas_limit_too_big` | `gas_limit` exceeds the signed 64-bit maximum |
  | `:invalid_base_fee` | `base_fee_per_gas` differs from the value derived from the parent (EIP-1559, from London) |
  | `:invalid_difficulty` | `difficulty` is 0 before Paris or not 0 from Paris (EIP-3675) |
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

  ## State Errors

  A backend callback that returns `{:error, reason}` aborts `EEVM.run/2`,
  `EEVM.transact/4`, and `EEVM.Block.execute/4` and `build/4` with
  `{:error, {:database, reason}}`; see `EEVM.Database`.

  | Error | Source | Meaning |
  |-------|--------|---------|
  | `:commit_not_supported` | `EEVM.Database.commit/1` | The backend's `commit/2` returned `{:error, :unsupported}`; apply `changes/1` yourself |

  ## Registry Errors

  | Error | Source | Meaning |
  |-------|--------|---------|
  | `:unknown_opcode` | `EEVM.Interpreter.Instructions.Registry` | Opcode byte has no known metadata |

  ## Execution status

  `EEVM.CallResult` and `EEVM.TransactionResult` report how execution ended
  in `status`, which is not an error:

  - `:success` — STOP or RETURN
  - `:revert` — REVERT; the call's state changes are undone and unused gas
    is returned
  - `{:halt, reason}` — an exceptional halt that consumes all the call's
    gas, with an execution or precompile error from this module as `reason`
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
          | :invalid_opcode
          | :create_collision
          | :code_size_limit_exceeded
          | :invalid_code_prefix

  @type precompile_error ::
          :out_of_gas
          | :invalid_input
          | :invalid_point
          | :invalid_versioned_hash
          | :invalid_field_element
          | :proof_verification_failed
          | :not_implemented

  @type decode_error ::
          :invalid_transaction_input
          | :empty_input
          | :invalid_type
          | :hex_string
          | :invalid_rlp
          | :invalid_rlp_integer
          | :invalid_fields
          | :invalid_v
          | :invalid_chain_id
          | :invalid_signature
          | :invalid_private_key

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
          | :too_many_blobs
          | :invalid_versioned_hash
          | :blob_fee_too_low
          | :initcode_too_large
          | :effective_gas_price_below_basefee

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

  @typedoc "Why execution halted exceptionally: the `reason` in `{:halt, reason}`."
  @type halt_reason :: execution_error() | precompile_error()

  @typedoc "Every error reason eevm returns."
  @type reason ::
          execution_error()
          | precompile_error()
          | :unknown_opcode
          | :commit_not_supported
          | decode_error()
          | transaction_validation_error()
          | block_error()

  @messages %{
    stack_underflow: "stack underflow",
    stack_overflow: "stack overflow (more than 1024 items)",
    out_of_gas: "out of gas",
    invalid_jump_destination: "jump to an invalid destination",
    static_state_modification: "state modification inside a static call",
    return_data_out_of_bounds: "read past the end of the return data",
    initcode_too_large: "initcode larger than 49152 bytes",
    insufficient_balance: "insufficient balance",
    invalid_opcode: "invalid opcode",
    create_collision: "contract address already in use",
    code_size_limit_exceeded: "deployed code larger than 24576 bytes",
    invalid_code_prefix: "deployed code starts with 0xEF",
    invalid_input: "invalid precompile input",
    invalid_point: "point not on the curve",
    invalid_versioned_hash: "invalid blob versioned hash",
    invalid_field_element: "invalid field element",
    proof_verification_failed: "KZG proof verification failed",
    not_implemented: "precompile not implemented",
    unknown_opcode: "unknown opcode",
    invalid_transaction_input: "not a transaction struct or binary",
    empty_input: "empty transaction encoding",
    invalid_type: "unknown transaction type",
    hex_string: "transaction bytes are a hex string; decode them with EEVM.bytes/1",
    invalid_rlp: "invalid RLP",
    invalid_rlp_integer: "non-canonical RLP integer",
    invalid_fields: "wrong transaction fields for its type",
    invalid_v: "invalid signature v value",
    invalid_chain_id: "transaction signed for another chain id",
    invalid_signature: "invalid signature",
    invalid_private_key: "invalid private key",
    tx_type_not_supported: "transaction type not supported by this hardfork",
    set_code_tx_no_creation: "set-code transaction can't create a contract",
    empty_authorization_list: "set-code transaction with no authorizations",
    invalid_authorization: "invalid authorization",
    intrinsic_gas_too_low: "gas limit below the intrinsic gas",
    gas_limit_exceeds_cap: "gas limit above the 2^24 transaction cap",
    gas_limit_exceeds_block: "gas limit above the block gas limit",
    nonce_too_low: "nonce too low",
    nonce_too_high: "nonce too high",
    nonce_is_max: "nonce at its maximum",
    priority_fee_above_max_fee: "priority fee above max fee",
    max_fee_below_basefee: "max fee below the base fee",
    sender_not_eoa: "sender is not an externally owned account",
    blob_tx_no_creation: "blob transaction can't create a contract",
    no_blob_data: "blob transaction without blobs",
    too_many_blobs: "too many blobs in one transaction",
    blob_fee_too_low: "max blob fee below the blob base fee",
    effective_gas_price_below_basefee: "effective gas price below the base fee",
    unknown_parent: "parent hash doesn't match the parent",
    invalid_block_number: "block number isn't the parent's plus one",
    invalid_timestamp: "timestamp not after the parent's",
    extra_data_too_big: "extra data longer than 32 bytes",
    invalid_gas_limit: "gas limit out of range",
    gas_limit_too_big: "gas limit above 2^63 - 1",
    invalid_base_fee: "wrong base fee",
    invalid_difficulty: "zero difficulty before the Merge or nonzero difficulty after it",
    invalid_nonce: "nonzero header nonce after the Merge",
    invalid_ommers_hash: "wrong ommers hash",
    missing_header_fields: "header is missing a field its fork defines",
    unexpected_header_fields: "header has a field from a later fork",
    invalid_blob_gas_used: "wrong blob gas used",
    invalid_excess_blob_gas: "wrong excess blob gas",
    invalid_block_encoding: "invalid block encoding",
    rlp_block_size_exceeded: "block larger than the RLP size limit",
    invalid_transactions_root: "wrong transactions root",
    invalid_withdrawals_root: "wrong withdrawals root",
    invalid_gas_used: "wrong gas used",
    invalid_logs_bloom: "wrong logs bloom",
    invalid_receipts_root: "wrong receipts root",
    invalid_state_root: "wrong state root",
    invalid_deposit_event_layout: "malformed deposit event",
    system_contract_empty: "request system contract has no code",
    system_contract_call_failed: "request system contract call failed",
    invalid_requests_hash: "wrong requests hash",
    commit_not_supported: "the database backend does not support commit",
    gas_allowance_exceeded: "transaction gas limit above the gas left in the block"
  }

  @doc """
  Returns a short human-readable description of `reason`.

  ## Examples

      iex> EEVM.Error.message(:nonce_too_low)
      "nonce too low"
      iex> EEVM.Error.message({:tx_failed, 2, :intrinsic_gas_too_low})
      "transaction 2 failed: gas limit below the intrinsic gas"
  """
  @spec message(reason() | :gas_allowance_exceeded | term()) :: String.t()
  def message({:tx_failed, index, reason}), do: "transaction #{index} failed: #{message(reason)}"
  def message(reason) when is_map_key(@messages, reason), do: Map.fetch!(@messages, reason)
  def message(reason), do: inspect(reason)
end
