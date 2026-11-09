defmodule EEVM.Block.Header do
  @moduledoc """
  Ethereum block header — the consensus-critical metadata for a block, with
  its canonical RLP codec (`encode/1`, `decode/1`), its hash
  (`compute_hash/1`), and the EIP-1559 base fee a child must carry
  (`calc_base_fee_per_gas/1`). Validation lives in `EEVM.Block.HeaderValidator`.

  ### Fields

  | Field | Description |
  |-------|-------------|
  | `parent_hash` | Keccak hash of the parent header |
  | `ommers_hash` | Keccak hash of the RLP ommers list (the empty-list hash post-Merge) |
  | `coinbase` | Address of the block producer (fee recipient) |
  | `state_root` | Post-execution world-state MPT root |
  | `transactions_root` | MPT root of `{rlp(index) => encoded transaction}` |
  | `receipts_root` | MPT root of `{rlp(index) => encoded receipt}` |
  | `logs_bloom` | 256-byte bloom summarising every log in the block |
  | `difficulty` | Proof-of-work difficulty (always zero post-Merge) |
  | `number` | Block number (height on the chain) |
  | `gas_limit` | Maximum cumulative gas the block may consume |
  | `gas_used` | Total gas the block's transactions consumed |
  | `timestamp` | Block timestamp in seconds since epoch |
  | `extra_data` | Arbitrary producer bytes (at most 32 bytes) |
  | `prev_randao` | Mix hash; the beacon chain's RANDAO mix post-Merge (PREVRANDAO) |
  | `nonce` | 8-byte proof-of-work nonce (all zero post-Merge) |
  | `base_fee_per_gas` | EIP-1559 base fee; `nil` before London |
  | `withdrawals_root` | EIP-4895 MPT root of the block's withdrawals; `nil` before Shanghai |
  | `blob_gas_used` | EIP-4844 blob gas consumed by the block; `nil` before Cancun |
  | `excess_blob_gas` | EIP-4844 running excess blob gas; `nil` before Cancun |
  | `parent_beacon_block_root` | EIP-4788 beacon root of the parent slot; `nil` before Cancun |
  | `requests_hash` | EIP-7685 commitment to the block's requests; `nil` before Prague |
  | `hash` | Keccak hash of this header. Set by `decode/1`; `compute_hash/1` derives it |

  The fork-dependent fields at the end are `nil` when absent, so a header
  encodes with exactly the fields it carries and `decode/1` followed by
  `encode/1` reproduces the input bytes.
  """

  # keccak256(rlp([]))
  @empty_ommers_hash Base.decode16!(
                       "1DCC4DE8DEC75D7AAB85B567B6CCD41AD312451B948A7413F0A142FD40D49347"
                     )

  # EIP-1559
  @elasticity_multiplier 2
  # EIP-1559: base fee of London's first block
  @initial_base_fee 1_000_000_000
  @base_fee_max_change_denominator 8

  @type t :: %__MODULE__{
          parent_hash: binary(),
          ommers_hash: binary(),
          coinbase: non_neg_integer(),
          state_root: binary(),
          transactions_root: binary(),
          receipts_root: binary(),
          logs_bloom: binary(),
          difficulty: non_neg_integer(),
          number: non_neg_integer(),
          gas_limit: non_neg_integer(),
          gas_used: non_neg_integer(),
          timestamp: non_neg_integer(),
          extra_data: binary(),
          prev_randao: non_neg_integer(),
          nonce: binary(),
          base_fee_per_gas: non_neg_integer() | nil,
          withdrawals_root: binary() | nil,
          blob_gas_used: non_neg_integer() | nil,
          excess_blob_gas: non_neg_integer() | nil,
          parent_beacon_block_root: non_neg_integer() | nil,
          requests_hash: binary() | nil,
          hash: binary()
        }

  defstruct parent_hash: <<0::256>>,
            ommers_hash: @empty_ommers_hash,
            coinbase: 0,
            state_root: <<0::256>>,
            transactions_root: <<0::256>>,
            receipts_root: <<0::256>>,
            logs_bloom: <<0::2048>>,
            difficulty: 0,
            number: 0,
            gas_limit: 0,
            gas_used: 0,
            timestamp: 0,
            extra_data: <<>>,
            prev_randao: 0,
            nonce: <<0::64>>,
            base_fee_per_gas: nil,
            withdrawals_root: nil,
            blob_gas_used: nil,
            excess_blob_gas: nil,
            parent_beacon_block_root: nil,
            requests_hash: nil,
            hash: <<0::256>>

  # The fork-dependent fields, in RLP order after `nonce`.
  @fork_fields [
    :base_fee_per_gas,
    :withdrawals_root,
    :blob_gas_used,
    :excess_blob_gas,
    :parent_beacon_block_root,
    :requests_hash
  ]

  @doc """
  Returns the ommers hash of a block with no ommers, `keccak256(rlp([]))`,
  which every post-Merge header carries.
  """
  @spec empty_ommers_hash() :: binary()
  def empty_ommers_hash, do: @empty_ommers_hash

  @doc "Returns a header with default values and no fork-dependent fields."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Returns a header with the given overrides.

  ## Example

      iex> header = EEVM.Block.Header.new(number: 18_000_000, gas_limit: 30_000_000)
      iex> {header.number, header.gas_limit}
      {18_000_000, 30_000_000}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end

  @doc """
  Returns the RLP list for `header`, as embedded in an encoded block.

  Fork-dependent fields are emitted up to the last non-`nil` one, in the
  order London, Shanghai, Cancun, Prague define them.
  """
  @spec to_rlp(t()) :: [binary()]
  def to_rlp(%__MODULE__{} = header) do
    base = [
      header.parent_hash,
      header.ommers_hash,
      <<header.coinbase::unsigned-big-160>>,
      header.state_root,
      header.transactions_root,
      header.receipts_root,
      header.logs_bloom,
      encode_uint(header.difficulty),
      encode_uint(header.number),
      encode_uint(header.gas_limit),
      encode_uint(header.gas_used),
      encode_uint(header.timestamp),
      header.extra_data,
      <<header.prev_randao::unsigned-big-256>>,
      header.nonce
    ]

    fork_values =
      @fork_fields
      |> Enum.map(&encode_fork_field(&1, Map.fetch!(header, &1)))
      |> Enum.reverse()
      |> Enum.drop_while(&is_nil/1)
      |> Enum.reverse()
      |> Enum.map(&(&1 || <<>>))

    base ++ fork_values
  end

  @doc """
  Encodes `header` as canonical RLP.

  ## Example

      iex> header = EEVM.Block.Header.new(number: 1, gas_limit: 30_000_000, base_fee_per_gas: 7)
      iex> {:ok, decoded} = header |> EEVM.Block.Header.encode() |> EEVM.Block.Header.decode()
      iex> {decoded.number, decoded.base_fee_per_gas, decoded.withdrawals_root}
      {1, 7, nil}
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = header), do: header |> to_rlp() |> ExRLP.encode()

  @doc """
  Decodes a canonical RLP header and sets `hash` to `keccak256(bytes)`.

  Returns `{:error, :invalid_block_encoding}` for malformed RLP, a field of
  the wrong size, a non-canonical integer, or an unknown field count.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid_block_encoding}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, fields} <- safe_rlp_decode(bytes),
         {:ok, header} <- from_rlp(fields) do
      if encode(header) == bytes,
        do: {:ok, %{header | hash: ExKeccak.hash_256(bytes)}},
        else: {:error, :invalid_block_encoding}
    end
  end

  @doc """
  Builds a header from its decoded RLP list (as found inside a block), with
  `hash` set to the keccak of the list's encoding.
  """
  @spec from_rlp(term()) :: {:ok, t()} | {:error, :invalid_block_encoding}
  def from_rlp([_ | _] = fields) when length(fields) in 15..21 do
    {base, fork_values} = Enum.split(fields, 15)

    with {:ok, header} <- decode_base(base),
         {:ok, header} <- decode_fork_fields(header, fork_values) do
      {:ok, %{header | hash: ExKeccak.hash_256(ExRLP.encode(fields))}}
    end
  end

  def from_rlp(_), do: {:error, :invalid_block_encoding}

  @doc """
  Returns `keccak256(encode(header))`, the hash children reference as
  `parent_hash`.
  """
  @spec compute_hash(t()) :: binary()
  def compute_hash(%__MODULE__{} = header), do: header |> encode() |> ExKeccak.hash_256()

  @doc """
  Returns the `base_fee_per_gas` a child of `parent` must carry (EIP-1559):
  the parent's base fee moved by at most 1/8 towards its gas use relative to
  its gas target (`gas_limit / 2`), rising by at least 1 wei above target.
  A parent without a base fee is the last block before London, so its child
  is London's first block and carries the initial 1 gwei.

  ## Example

      iex> parent = EEVM.Block.Header.new(gas_limit: 30_000_000, gas_used: 30_000_000, base_fee_per_gas: 800)
      iex> EEVM.Block.Header.calc_base_fee_per_gas(parent)
      900
  """
  @spec calc_base_fee_per_gas(t()) :: non_neg_integer()
  def calc_base_fee_per_gas(%__MODULE__{base_fee_per_gas: nil}), do: @initial_base_fee

  def calc_base_fee_per_gas(%__MODULE__{gas_limit: limit, gas_used: used} = parent) do
    fee = parent.base_fee_per_gas
    target = div(limit, @elasticity_multiplier)

    cond do
      used == target ->
        fee

      used > target ->
        fee + max(div(div(fee * (used - target), target), @base_fee_max_change_denominator), 1)

      true ->
        fee - div(div(fee * (target - used), target), @base_fee_max_change_denominator)
    end
  end

  defp decode_base([
         parent_hash,
         ommers_hash,
         coinbase,
         state_root,
         transactions_root,
         receipts_root,
         logs_bloom,
         difficulty,
         number,
         gas_limit,
         gas_used,
         timestamp,
         extra_data,
         mix_hash,
         nonce
       ])
       when byte_size(parent_hash) == 32 and byte_size(ommers_hash) == 32 and
              byte_size(coinbase) == 20 and byte_size(state_root) == 32 and
              byte_size(transactions_root) == 32 and byte_size(receipts_root) == 32 and
              byte_size(logs_bloom) == 256 and is_binary(extra_data) and
              byte_size(mix_hash) == 32 and byte_size(nonce) == 8 do
    with {:ok, difficulty} <- decode_uint(difficulty),
         {:ok, number} <- decode_uint(number),
         {:ok, gas_limit} <- decode_uint(gas_limit),
         {:ok, gas_used} <- decode_uint(gas_used),
         {:ok, timestamp} <- decode_uint(timestamp) do
      {:ok,
       %__MODULE__{
         parent_hash: parent_hash,
         ommers_hash: ommers_hash,
         coinbase: :binary.decode_unsigned(coinbase),
         state_root: state_root,
         transactions_root: transactions_root,
         receipts_root: receipts_root,
         logs_bloom: logs_bloom,
         difficulty: difficulty,
         number: number,
         gas_limit: gas_limit,
         gas_used: gas_used,
         timestamp: timestamp,
         extra_data: extra_data,
         prev_randao: :binary.decode_unsigned(mix_hash),
         nonce: nonce
       }}
    end
  end

  defp decode_base(_), do: {:error, :invalid_block_encoding}

  defp decode_fork_fields(header, values) do
    @fork_fields
    |> Enum.zip(values)
    |> Enum.reduce_while({:ok, header}, fn {field, value}, {:ok, acc} ->
      case decode_fork_field(field, value) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, field, decoded)}}
        error -> {:halt, error}
      end
    end)
  end

  defp decode_fork_field(field, <<_::256>> = value)
       when field in [:withdrawals_root, :requests_hash],
       do: {:ok, value}

  defp decode_fork_field(:parent_beacon_block_root, <<value::unsigned-big-256>>), do: {:ok, value}

  defp decode_fork_field(field, value)
       when field in [:base_fee_per_gas, :blob_gas_used, :excess_blob_gas],
       do: decode_uint(value)

  defp decode_fork_field(_field, _value), do: {:error, :invalid_block_encoding}

  defp encode_fork_field(_field, nil), do: nil
  defp encode_fork_field(:parent_beacon_block_root, root), do: <<root::unsigned-big-256>>

  defp encode_fork_field(field, value) when field in [:withdrawals_root, :requests_hash],
    do: value

  defp encode_fork_field(_field, value), do: encode_uint(value)

  @doc false
  @spec encode_uint(non_neg_integer()) :: binary()
  def encode_uint(0), do: <<>>
  def encode_uint(value) when is_integer(value) and value > 0, do: :binary.encode_unsigned(value)

  # RLP integers are big-endian with no leading zero bytes.
  @doc false
  @spec decode_uint(term()) :: {:ok, non_neg_integer()} | {:error, :invalid_block_encoding}
  def decode_uint(<<>>), do: {:ok, 0}
  def decode_uint(<<0, _::binary>>), do: {:error, :invalid_block_encoding}
  def decode_uint(value) when is_binary(value), do: {:ok, :binary.decode_unsigned(value)}
  def decode_uint(_), do: {:error, :invalid_block_encoding}

  @doc false
  @spec safe_rlp_decode(binary()) :: {:ok, term()} | {:error, :invalid_block_encoding}
  def safe_rlp_decode(bytes) do
    {:ok, ExRLP.decode(bytes)}
  rescue
    _ -> {:error, :invalid_block_encoding}
  end
end
