defmodule EEVM.Transaction do
  @moduledoc """
  Ethereum transaction wire-format structs.

  These structs represent signed transaction payloads as they appear on the
  network (legacy and typed transaction envelopes). They are intentionally
  separate from `EEVM.Context.Transaction`, which models execution context.
  """

  @type address :: binary()
  @type hash32 :: binary()
  @type access_list :: [{address(), [hash32()]}]

  @type t ::
          EEVM.Transaction.Legacy.t()
          | EEVM.Transaction.AccessList.t()
          | EEVM.Transaction.FeeMarket.t()
          | EEVM.Transaction.Blob.t()
          | EEVM.Transaction.SetCode.t()

  @type authorization_tuple :: EEVM.Transaction.Authorization.t()

  defmodule Authorization do
    @moduledoc "EIP-7702 authorization tuple."

    @type t :: %__MODULE__{
            chain_id: non_neg_integer(),
            address: EEVM.Transaction.address(),
            nonce: non_neg_integer(),
            y_parity: 0 | 1,
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
            to: binary(),
            value: non_neg_integer(),
            data: binary(),
            v: non_neg_integer(),
            r: non_neg_integer(),
            s: non_neg_integer()
          }

    defstruct [:nonce, :gas_price, :gas_limit, :to, :value, :data, :v, :r, :s]
  end

  defmodule AccessList do
    @moduledoc "EIP-2930 access list transaction (type 1)."

    @type t :: %__MODULE__{
            chain_id: non_neg_integer(),
            nonce: non_neg_integer(),
            gas_price: non_neg_integer(),
            gas_limit: non_neg_integer(),
            to: binary(),
            value: non_neg_integer(),
            data: binary(),
            access_list: EEVM.Transaction.access_list(),
            y_parity: 0 | 1,
            r: non_neg_integer(),
            s: non_neg_integer()
          }

    defstruct [
      :chain_id,
      :nonce,
      :gas_price,
      :gas_limit,
      :to,
      :value,
      :data,
      :access_list,
      :y_parity,
      :r,
      :s
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
            to: binary(),
            value: non_neg_integer(),
            data: binary(),
            access_list: EEVM.Transaction.access_list(),
            y_parity: 0 | 1,
            r: non_neg_integer(),
            s: non_neg_integer()
          }

    defstruct [
      :chain_id,
      :nonce,
      :max_priority_fee_per_gas,
      :max_fee_per_gas,
      :gas_limit,
      :to,
      :value,
      :data,
      :access_list,
      :y_parity,
      :r,
      :s
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
      :nonce,
      :max_priority_fee_per_gas,
      :max_fee_per_gas,
      :gas_limit,
      :to,
      :value,
      :data,
      :access_list,
      :max_fee_per_blob_gas,
      :blob_versioned_hashes,
      :y_parity,
      :r,
      :s
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
      :nonce,
      :max_priority_fee_per_gas,
      :max_fee_per_gas,
      :gas_limit,
      :to,
      :value,
      :data,
      :access_list,
      :authorization_list,
      :y_parity,
      :r,
      :s
    ]
  end
end
