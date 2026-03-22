defmodule EEVM.TestSupport.StateTestFixture do
  alias EEVM.Context.{Block, Transaction}

  @empty_logs_hash "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347"

  defmodule Case do
    @type t :: %__MODULE__{
            name: String.t(),
            env: EEVM.TestSupport.StateTestFixture.Env.t(),
            pre_accounts: %{non_neg_integer() => map()},
            pre_storage: %{non_neg_integer() => %{non_neg_integer() => non_neg_integer()}},
            transaction: EEVM.TestSupport.StateTestFixture.TransactionTemplate.t(),
            post: %{EEVM.HardforkConfig.spec_id() => [EEVM.TestSupport.StateTestFixture.PostExpectation.t()]}
          }

    defstruct [:name, :env, :pre_accounts, :pre_storage, :transaction, :post]
  end

  defmodule Env do
    @type t :: %__MODULE__{
            coinbase: non_neg_integer(),
            number: non_neg_integer(),
            timestamp: non_neg_integer(),
            gas_limit: non_neg_integer(),
            base_fee: non_neg_integer(),
            blob_base_fee: non_neg_integer(),
            prevrandao: non_neg_integer(),
            chain_id: non_neg_integer(),
            hashes: %{non_neg_integer() => non_neg_integer()}
          }

    defstruct [
      :coinbase,
      :number,
      :timestamp,
      :gas_limit,
      :base_fee,
      :blob_base_fee,
      :prevrandao,
      :chain_id,
      :hashes
    ]
  end

  defmodule TransactionTemplate do
    @type t :: %__MODULE__{
            nonce: non_neg_integer(),
            secret_key: binary(),
            to: non_neg_integer() | nil,
            gas_price: non_neg_integer(),
            max_fee_per_gas: non_neg_integer(),
            max_priority_fee_per_gas: non_neg_integer(),
            max_fee_per_blob_gas: non_neg_integer(),
            access_list: [{non_neg_integer(), [non_neg_integer()]}],
            blob_hashes: [non_neg_integer()],
            type: :legacy | :eip2930 | :eip1559 | :eip4844,
            data: [binary()],
            gas_limit: [non_neg_integer()],
            value: [non_neg_integer()]
          }

    defstruct [
      :nonce,
      :secret_key,
      :to,
      :gas_price,
      :max_fee_per_gas,
      :max_priority_fee_per_gas,
      :max_fee_per_blob_gas,
      :access_list,
      :blob_hashes,
      :type,
      data: [],
      gas_limit: [],
      value: []
    ]
  end

  defmodule PostExpectation do
    @type t :: %__MODULE__{
            hardfork: EEVM.HardforkConfig.spec_id(),
            hash: binary(),
            logs: binary(),
            expect_exception: String.t() | nil,
            indexes: %{data: non_neg_integer(), gas: non_neg_integer(), value: non_neg_integer()}
          }

    defstruct [:hardfork, :hash, :logs, :expect_exception, indexes: %{data: 0, gas: 0, value: 0}]
  end

  @spec load_file!(binary()) :: [Case.t()]
  def load_file!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn {name, payload} ->
      %Case{
        name: name,
        env: parse_env(Map.fetch!(payload, "env")),
        pre_accounts: parse_pre_accounts(Map.fetch!(payload, "pre")),
        pre_storage: parse_pre_storage(Map.fetch!(payload, "pre")),
        transaction: parse_transaction(Map.fetch!(payload, "transaction")),
        post: parse_post(Map.fetch!(payload, "post"))
      }
    end)
  end

  @spec block(Env.t()) :: Block.t()
  def block(%Env{} = env) do
    Block.new(
      coinbase: env.coinbase,
      number: env.number,
      timestamp: env.timestamp,
      gaslimit: env.gas_limit,
      basefee: env.base_fee,
      blob_base_fee: env.blob_base_fee,
      prevrandao: env.prevrandao,
      chain_id: env.chain_id,
      hashes: env.hashes
    )
  end

  @spec expectations(Case.t()) :: [PostExpectation.t()]
  def expectations(%Case{post: post}) do
    Enum.flat_map(post, fn {_fork, expectations} -> expectations end)
  end

  @spec build_transaction(Case.t(), PostExpectation.t()) :: Transaction.t()
  def build_transaction(%Case{transaction: tx_template}, %PostExpectation{indexes: indexes, hardfork: hardfork}) do
    origin = secret_key_to_address(tx_template.secret_key)

    base_gas_price =
      cond do
        tx_template.type in [:eip1559, :eip4844] -> 0
        true -> tx_template.gas_price
      end

    Transaction.new(
      origin: origin,
      nonce: tx_template.nonce,
      gas_limit: Enum.fetch!(tx_template.gas_limit, indexes.gas),
      to: tx_template.to,
      value: Enum.fetch!(tx_template.value, indexes.value),
      data: Enum.fetch!(tx_template.data, indexes.data),
      gasprice: base_gas_price,
      max_fee_per_gas: tx_template.max_fee_per_gas,
      max_priority_fee_per_gas: tx_template.max_priority_fee_per_gas,
      access_list: tx_template.access_list,
      blob_hashes: tx_template.blob_hashes,
      max_fee_per_blob_gas: tx_template.max_fee_per_blob_gas,
      type: tx_type_for_hardfork(tx_template.type, hardfork)
    )
  end

  defp parse_env(env) do
    %Env{
      coinbase: parse_address!(Map.fetch!(env, "currentCoinbase")),
      number: parse_quantity!(Map.get(env, "currentNumber", "0x0")),
      timestamp: parse_quantity!(Map.get(env, "currentTimestamp", "0x0")),
      gas_limit: parse_quantity!(Map.get(env, "currentGasLimit", "0x0")),
      base_fee: parse_quantity!(Map.get(env, "currentBaseFee", "0x0")),
      blob_base_fee: parse_quantity!(Map.get(env, "currentBlobBaseFee", "0x0")),
      prevrandao: parse_quantity!(Map.get(env, "currentRandom", Map.get(env, "currentDifficulty", "0x0"))),
      chain_id: parse_quantity!(Map.get(env, "currentChainId", "0x1")),
      hashes: %{}
    }
  end

  defp parse_pre_accounts(pre) do
    Enum.into(pre, %{}, fn {address, account} ->
      {parse_address!(address),
       %{
         balance: parse_quantity!(Map.get(account, "balance", "0x0")),
         nonce: parse_quantity!(Map.get(account, "nonce", "0x0")),
         code: parse_bytes!(Map.get(account, "code", "0x"))
       }}
    end)
  end

  defp parse_pre_storage(pre) do
    Enum.reduce(pre, %{}, fn {address, account}, acc ->
      storage =
        account
        |> Map.get("storage", %{})
        |> Enum.into(%{}, fn {slot, value} ->
          {parse_quantity!(slot), parse_quantity!(value)}
        end)

      if map_size(storage) == 0 do
        acc
      else
        Map.put(acc, parse_address!(address), storage)
      end
    end)
  end

  defp parse_transaction(tx) do
    %TransactionTemplate{
      nonce: parse_quantity!(Map.get(tx, "nonce", "0x0")),
      secret_key: parse_bytes!(Map.fetch!(tx, "secretKey")),
      to: parse_optional_address(Map.get(tx, "to", "")),
      gas_price: parse_quantity!(Map.get(tx, "gasPrice", "0x0")),
      max_fee_per_gas: parse_quantity!(Map.get(tx, "maxFeePerGas", "0x0")),
      max_priority_fee_per_gas: parse_quantity!(Map.get(tx, "maxPriorityFeePerGas", "0x0")),
      max_fee_per_blob_gas: parse_quantity!(Map.get(tx, "maxFeePerBlobGas", "0x0")),
      access_list: parse_access_list(Map.get(tx, "accessLists", [])),
      blob_hashes: parse_blob_hashes(Map.get(tx, "blobVersionedHashes", [])),
      type: parse_tx_type(Map.get(tx, "type", nil)),
      data: parse_binary_list(Map.get(tx, "data", ["0x"])),
      gas_limit: parse_quantity_list(Map.get(tx, "gasLimit", ["0x0"])),
      value: parse_quantity_list(Map.get(tx, "value", ["0x0"]))
    }
  end

  defp parse_post(post) do
    Enum.into(post, %{}, fn {fork_name, expectations} ->
      hardfork = parse_hardfork!(fork_name)

      parsed =
        Enum.map(expectations, fn expectation ->
          %PostExpectation{
            hardfork: hardfork,
            hash: parse_bytes!(Map.fetch!(expectation, "hash")),
            logs: parse_bytes!(Map.get(expectation, "logs", @empty_logs_hash)),
            expect_exception: Map.get(expectation, "expectException"),
            indexes: %{
              data: get_in(expectation, ["indexes", "data"]) || 0,
              gas: get_in(expectation, ["indexes", "gas"]) || 0,
              value: get_in(expectation, ["indexes", "value"]) || 0
            }
          }
        end)

      {hardfork, parsed}
    end)
  end

  defp parse_binary_list(values) when is_list(values), do: Enum.map(values, &parse_bytes!/1)

  defp parse_quantity_list(values) when is_list(values), do: Enum.map(values, &parse_quantity!/1)

  defp parse_access_list([]), do: []

  defp parse_access_list([first | _] = access_lists) when is_list(first) do
    access_lists
    |> hd()
    |> Enum.map(fn entry ->
      {parse_address!(Map.fetch!(entry, "address")), Enum.map(Map.get(entry, "storageKeys", []), &parse_quantity!/1)}
    end)
  end

  defp parse_access_list(_), do: []

  defp parse_blob_hashes(values) when is_list(values), do: Enum.map(values, &parse_quantity!/1)

  defp parse_tx_type(nil), do: :legacy
  defp parse_tx_type("0x0"), do: :legacy
  defp parse_tx_type("0x1"), do: :eip2930
  defp parse_tx_type("0x2"), do: :eip1559
  defp parse_tx_type("0x3"), do: :eip4844
  defp parse_tx_type(_), do: :legacy

  defp tx_type_for_hardfork(type, _hardfork), do: type

  defp parse_hardfork!("Frontier"), do: :frontier
  defp parse_hardfork!("Homestead"), do: :homestead
  defp parse_hardfork!("EIP150"), do: :tangerine_whistle
  defp parse_hardfork!("EIP158"), do: :spurious_dragon
  defp parse_hardfork!("Byzantium"), do: :byzantium
  defp parse_hardfork!("Constantinople"), do: :constantinople
  defp parse_hardfork!("ConstantinopleFix"), do: :constantinople
  defp parse_hardfork!("Istanbul"), do: :istanbul
  defp parse_hardfork!("Berlin"), do: :berlin
  defp parse_hardfork!("London"), do: :london
  defp parse_hardfork!("Paris"), do: :paris
  defp parse_hardfork!("Merge"), do: :paris
  defp parse_hardfork!("Shanghai"), do: :shanghai
  defp parse_hardfork!("Cancun"), do: :cancun
  defp parse_hardfork!("Prague"), do: :prague
  defp parse_hardfork!(other), do: raise(ArgumentError, "unsupported hardfork #{inspect(other)}")

  defp parse_optional_address(""), do: nil
  defp parse_optional_address("0x"), do: nil
  defp parse_optional_address(value), do: parse_address!(value)

  defp parse_address!(value) do
    value
    |> parse_bytes!()
    |> :binary.decode_unsigned()
  end

  defp parse_quantity!("0x"), do: 0
  defp parse_quantity!(""), do: 0

  defp parse_quantity!("0x" <> hex) do
    if hex == "" do
      0
    else
      String.to_integer(hex, 16)
    end
  end

  defp parse_quantity!(value) when is_integer(value), do: value

  defp parse_bytes!("0x" <> hex) do
    Base.decode16!(String.upcase(hex), case: :mixed)
  end

  defp parse_bytes!(value) when is_binary(value), do: value

  defp secret_key_to_address(secret_key) when is_binary(secret_key) do
    public_key = :crypto.generate_key(:ecdh, :secp256k1, secret_key)

    raw_public_key =
      case public_key do
        <<4, key::binary-size(64)>> -> key
        <<_::binary-size(64)>> = key -> key
      end

    <<_::binary-size(12), address::binary-size(20)>> = ExKeccak.hash_256(raw_public_key)
    :binary.decode_unsigned(address)
  end
end
