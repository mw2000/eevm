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
    EIP-7702 authorization tuple.

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
    @moduledoc "Legacy transaction (type 0)."

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
    @moduledoc "EIP-2930 access list transaction (type 1)."

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
    @moduledoc "EIP-1559 fee market transaction (type 2)."

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
    @moduledoc "EIP-4844 blob transaction (type 3)."

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
    @moduledoc "EIP-7702 set-code transaction (type 4)."

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
