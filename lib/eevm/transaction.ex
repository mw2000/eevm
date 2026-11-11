defmodule EEVM.Transaction do
  @moduledoc """
  Ethereum transaction wire-format structs.

  These structs represent signed transaction payloads as they appear on the
  network (legacy and typed transaction envelopes). They are intentionally
  separate from `EEVM.TxEnv`, which models execution context.

  `nonce`, `value`, `data`, `access_list`, and `authorization_list` default to
  zero or empty. Build an unsigned struct and sign it with
  `EEVM.Transaction.Signer.sign/3`, which also fills in a missing `chain_id`.

  Addresses are integers, as everywhere in eevm: `to` (`nil` creates a
  contract), access-list entries, and `Authorization.address`. Access-list
  storage keys are integers too; `EEVM.Transaction.Envelope` converts at the
  wire edge. A 20-byte binary address or 32-byte binary storage key is still
  accepted for one minor version, but is deprecated.

  ## Fields

  Each type's page lists the fields it has. Amounts are in wei.

  | Field | Types | Description |
  |-------|-------|-------------|
  | `chain_id` | typed | Chain the transaction is valid on; `Signer.sign/3` fills in a `nil` one from the config |
  | `nonce` | all | The sender's account nonce |
  | `gas_price` | legacy, access list | Price per unit of gas |
  | `max_fee_per_gas` | fee market, blob, set code | Most the sender pays per unit of gas, base fee included (EIP-1559) |
  | `max_priority_fee_per_gas` | fee market, blob, set code | Most of that the block producer receives as a tip (EIP-1559) |
  | `gas_limit` | all | Gas available to the transaction, intrinsic gas included |
  | `to` | all | Recipient address; `nil` creates a contract (not allowed for blob and set-code transactions) |
  | `value` | all | Wei sent to `to` or to the new contract |
  | `data` | all | Calldata, or initcode when `to` is `nil` |
  | `access_list` | typed | `[{address, [storage_key]}]` warmed before execution (EIP-2930) |
  | `max_fee_per_blob_gas` | blob | Most the sender pays per unit of blob gas (EIP-4844) |
  | `blob_versioned_hashes` | blob | 32-byte versioned hashes of the blobs (EIP-4844) |
  | `authorization_list` | set code | `EEVM.Transaction.Authorization` tuples to apply (EIP-7702) |
  | `v` | legacy | Signature recovery value: 27/28, or `chain_id * 2 + 35/36` with EIP-155 |
  | `y_parity` | typed | Signature recovery bit, 0 or 1 |
  | `r`, `s` | all | The secp256k1 signature |
  """

  @type address :: non_neg_integer()
  @type storage_key :: non_neg_integer()
  @type hash32 :: <<_::256>>
  @type access_list :: [{address(), [storage_key()]}]

  @type t ::
          EEVM.Transaction.Legacy.t()
          | EEVM.Transaction.AccessList.t()
          | EEVM.Transaction.FeeMarket.t()
          | EEVM.Transaction.Blob.t()
          | EEVM.Transaction.SetCode.t()

  @type authorization_tuple :: EEVM.Transaction.Authorization.t()

  @doc false
  # The wire bytes of `to` and of access-list and authorization addresses.
  # Also takes the deprecated 20-byte binary form.
  @spec address_bytes(address() | binary() | nil) :: binary()
  def address_bytes(nil), do: <<>>
  def address_bytes(<<>>), do: <<>>
  def address_bytes(<<_::160>> = bytes), do: bytes
  def address_bytes(address) when is_integer(address), do: <<address::unsigned-big-160>>

  @doc false
  # The RLP item list of an access list. Also takes the deprecated binary forms.
  @spec access_list_rlp(access_list()) :: [[binary() | [binary()]]]
  def access_list_rlp(access_list) do
    Enum.map(access_list, fn {address, keys} ->
      [address_bytes(address), Enum.map(keys, &storage_key_bytes/1)]
    end)
  end

  defp storage_key_bytes(<<_::256>> = key), do: key
  defp storage_key_bytes(key) when is_integer(key), do: <<key::unsigned-big-256>>

  defmodule Authorization do
    @moduledoc """
    EIP-7702 authorization tuple: the account that signs it (its authority,
    see `EEVM.Transaction.Signer.recover_authority/1`) lets `address`'s code
    run as its own.

    | Field | Description |
    |-------|-------------|
    | `chain_id` | Chain the authorization is valid on; 0 for any chain |
    | `address` | Address whose code the authority delegates to |
    | `nonce` | The authority's account nonce |
    | `y_parity`, `r`, `s` | The authority's secp256k1 signature |

    `y_parity` is a full byte on the wire; values other than 0 or 1 make the
    authorization unrecoverable, so it is skipped rather than rejected.
    """

    @type t :: %__MODULE__{
            chain_id: non_neg_integer(),
            address: EEVM.Transaction.address(),
            nonce: non_neg_integer(),
            y_parity: 0..255,
            r: non_neg_integer(),
            s: non_neg_integer()
          }

    defstruct [:chain_id, :address, :nonce, :y_parity, :r, :s]
  end

  defmodule Legacy do
    @moduledoc """
    Legacy transaction (type 0): `nonce`, `gas_price`, `gas_limit`, `to`,
    `value`, `data`, and the signature `v`, `r`, `s`. `EEVM.Transaction`
    describes each field.
    """

    @type t :: %__MODULE__{
            nonce: non_neg_integer(),
            gas_price: non_neg_integer(),
            gas_limit: non_neg_integer(),
            to: EEVM.Transaction.address() | nil,
            value: non_neg_integer(),
            data: binary(),
            v: non_neg_integer(),
            r: non_neg_integer(),
            s: non_neg_integer()
          }

    defstruct [:gas_price, :gas_limit, :to, :v, :r, :s, nonce: 0, value: 0, data: <<>>]
  end

  defmodule AccessList do
    @moduledoc """
    EIP-2930 access list transaction (type 1): `chain_id`, `nonce`,
    `gas_price`, `gas_limit`, `to`, `value`, `data`, `access_list`, and the
    signature `y_parity`, `r`, `s`. `EEVM.Transaction` describes each field.
    """

    @type t :: %__MODULE__{
            chain_id: non_neg_integer(),
            nonce: non_neg_integer(),
            gas_price: non_neg_integer(),
            gas_limit: non_neg_integer(),
            to: EEVM.Transaction.address() | nil,
            value: non_neg_integer(),
            data: binary(),
            access_list: EEVM.Transaction.access_list(),
            y_parity: 0 | 1,
            r: non_neg_integer(),
            s: non_neg_integer()
          }

    defstruct [
      :chain_id,
      :gas_price,
      :gas_limit,
      :to,
      :y_parity,
      :r,
      :s,
      nonce: 0,
      value: 0,
      data: <<>>,
      access_list: []
    ]
  end

  defmodule FeeMarket do
    @moduledoc """
    EIP-1559 fee market transaction (type 2): `chain_id`, `nonce`,
    `max_priority_fee_per_gas`, `max_fee_per_gas`, `gas_limit`, `to`,
    `value`, `data`, `access_list`, and the signature `y_parity`, `r`, `s`.
    `EEVM.Transaction` describes each field.
    """

    @type t :: %__MODULE__{
            chain_id: non_neg_integer(),
            nonce: non_neg_integer(),
            max_priority_fee_per_gas: non_neg_integer(),
            max_fee_per_gas: non_neg_integer(),
            gas_limit: non_neg_integer(),
            to: EEVM.Transaction.address() | nil,
            value: non_neg_integer(),
            data: binary(),
            access_list: EEVM.Transaction.access_list(),
            y_parity: 0 | 1,
            r: non_neg_integer(),
            s: non_neg_integer()
          }

    defstruct [
      :chain_id,
      :max_priority_fee_per_gas,
      :max_fee_per_gas,
      :gas_limit,
      :to,
      :y_parity,
      :r,
      :s,
      nonce: 0,
      value: 0,
      data: <<>>,
      access_list: []
    ]
  end

  defmodule Blob do
    @moduledoc """
    EIP-4844 blob transaction (type 3): `chain_id`, `nonce`,
    `max_priority_fee_per_gas`, `max_fee_per_gas`, `gas_limit`, `to`,
    `value`, `data`, `access_list`, `max_fee_per_blob_gas`,
    `blob_versioned_hashes`, and the signature `y_parity`, `r`, `s`.
    `EEVM.Transaction` describes each field.
    """

    @type t :: %__MODULE__{
            chain_id: non_neg_integer(),
            nonce: non_neg_integer(),
            max_priority_fee_per_gas: non_neg_integer(),
            max_fee_per_gas: non_neg_integer(),
            gas_limit: non_neg_integer(),
            to: EEVM.Transaction.address(),
            value: non_neg_integer(),
            data: binary(),
            access_list: EEVM.Transaction.access_list(),
            max_fee_per_blob_gas: non_neg_integer(),
            blob_versioned_hashes: [EEVM.Transaction.hash32()],
            y_parity: 0 | 1,
            r: non_neg_integer(),
            s: non_neg_integer()
          }

    defstruct [
      :chain_id,
      :max_priority_fee_per_gas,
      :max_fee_per_gas,
      :gas_limit,
      :to,
      :max_fee_per_blob_gas,
      :blob_versioned_hashes,
      :y_parity,
      :r,
      :s,
      nonce: 0,
      value: 0,
      data: <<>>,
      access_list: []
    ]
  end

  defmodule SetCode do
    @moduledoc """
    EIP-7702 set-code transaction (type 4): `chain_id`, `nonce`,
    `max_priority_fee_per_gas`, `max_fee_per_gas`, `gas_limit`, `to`,
    `value`, `data`, `access_list`, `authorization_list`, and the signature
    `y_parity`, `r`, `s`. `EEVM.Transaction` describes each field.
    """

    @type t :: %__MODULE__{
            chain_id: non_neg_integer(),
            nonce: non_neg_integer(),
            max_priority_fee_per_gas: non_neg_integer(),
            max_fee_per_gas: non_neg_integer(),
            gas_limit: non_neg_integer(),
            to: EEVM.Transaction.address(),
            value: non_neg_integer(),
            data: binary(),
            access_list: EEVM.Transaction.access_list(),
            authorization_list: [EEVM.Transaction.authorization_tuple()],
            y_parity: 0 | 1,
            r: non_neg_integer(),
            s: non_neg_integer()
          }

    defstruct [
      :chain_id,
      :max_priority_fee_per_gas,
      :max_fee_per_gas,
      :gas_limit,
      :to,
      :y_parity,
      :r,
      :s,
      nonce: 0,
      value: 0,
      data: <<>>,
      access_list: [],
      authorization_list: []
    ]
  end
end
