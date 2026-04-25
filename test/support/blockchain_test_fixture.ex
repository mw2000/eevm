defmodule EEVM.TestSupport.BlockchainTestFixture do
  @moduledoc """
  Parses official `BlockchainTests` JSON fixtures into typed structs.

  The schema differs from `GeneralStateTests`:

  - Top-level keys: `pre`, `postState`, `network`, `genesisBlockHeader`,
    `genesisRLP`, `blocks`, `lastblockhash`.
  - Each entry in `blocks` carries a parsed `blockHeader` plus a parsed
    `transactions` array (with the recovered `sender` already attached) and
    the canonical `rlp` of the whole block.
  - `InvalidBlocks` fixtures additionally include an `expectException`
    string on the offending block.

  This loader produces the shape the runner consumes; it does not run any
  semantic checks of its own.
  """

  defmodule Account do
    @type t :: %__MODULE__{
            balance: non_neg_integer(),
            nonce: non_neg_integer(),
            code: binary(),
            storage: %{non_neg_integer() => non_neg_integer()}
          }

    defstruct balance: 0, nonce: 0, code: <<>>, storage: %{}
  end

  defmodule TransactionFields do
    @type t :: %__MODULE__{
            sender: non_neg_integer(),
            nonce: non_neg_integer(),
            type: :legacy | :eip2930 | :eip1559 | :eip4844 | :eip7702,
            to: non_neg_integer() | nil,
            value: non_neg_integer(),
            data: binary(),
            gas_limit: non_neg_integer(),
            gas_price: non_neg_integer(),
            max_fee_per_gas: non_neg_integer(),
            max_priority_fee_per_gas: non_neg_integer(),
            max_fee_per_blob_gas: non_neg_integer(),
            access_list: [{non_neg_integer(), [non_neg_integer()]}],
            blob_hashes: [non_neg_integer()],
            chain_id: non_neg_integer()
          }

    defstruct sender: 0,
              nonce: 0,
              type: :legacy,
              to: nil,
              value: 0,
              data: <<>>,
              gas_limit: 0,
              gas_price: 0,
              max_fee_per_gas: 0,
              max_priority_fee_per_gas: 0,
              max_fee_per_blob_gas: 0,
              access_list: [],
              blob_hashes: [],
              chain_id: 1
  end

  defmodule BlockHeader do
    @type t :: %__MODULE__{
            parent_hash: binary(),
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
            mix_hash: non_neg_integer(),
            nonce: binary(),
            base_fee_per_gas: non_neg_integer(),
            withdrawals_root: binary() | nil,
            blob_gas_used: non_neg_integer() | nil,
            excess_blob_gas: non_neg_integer() | nil,
            parent_beacon_block_root: non_neg_integer() | nil,
            requests_hash: binary() | nil,
            hash: binary()
          }

    defstruct [
      :parent_hash,
      :coinbase,
      :state_root,
      :transactions_root,
      :receipts_root,
      :logs_bloom,
      :difficulty,
      :number,
      :gas_limit,
      :gas_used,
      :timestamp,
      :extra_data,
      :mix_hash,
      :nonce,
      :base_fee_per_gas,
      :withdrawals_root,
      :blob_gas_used,
      :excess_blob_gas,
      :parent_beacon_block_root,
      :requests_hash,
      :hash
    ]
  end

  defmodule Withdrawal do
    @type t :: %__MODULE__{
            index: non_neg_integer(),
            validator_index: non_neg_integer(),
            address: non_neg_integer(),
            amount: non_neg_integer()
          }

    defstruct [:index, :validator_index, :address, :amount]
  end

  defmodule Block do
    @type t :: %__MODULE__{
            block_number: non_neg_integer(),
            header: BlockHeader.t() | nil,
            rlp: binary(),
            transactions: [TransactionFields.t()],
            withdrawals: [Withdrawal.t()],
            expect_exception: String.t() | nil
          }

    defstruct [
      :block_number,
      :header,
      :rlp,
      transactions: [],
      withdrawals: [],
      expect_exception: nil
    ]
  end

  defmodule Case do
    @type t :: %__MODULE__{
            name: String.t(),
            network: EEVM.HardforkConfig.spec_id(),
            pre: %{non_neg_integer() => Account.t()},
            post: %{non_neg_integer() => Account.t()},
            genesis_header: BlockHeader.t(),
            last_block_hash: binary(),
            blocks: [Block.t()]
          }

    defstruct [:name, :network, :pre, :post, :genesis_header, :last_block_hash, blocks: []]
  end

  @spec load_file!(binary()) :: [Case.t()]
  def load_file!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn {name, payload} ->
      %Case{
        name: name,
        network: parse_network!(Map.fetch!(payload, "network")),
        pre: parse_accounts(Map.fetch!(payload, "pre")),
        post: parse_accounts(Map.get(payload, "postState", %{})),
        genesis_header: parse_block_header(Map.fetch!(payload, "genesisBlockHeader")),
        last_block_hash: parse_bytes!(Map.fetch!(payload, "lastblockhash")),
        blocks: parse_blocks(Map.fetch!(payload, "blocks"))
      }
    end)
  end

  defp parse_blocks(blocks) when is_list(blocks) do
    Enum.map(blocks, fn block ->
      %Block{
        block_number: parse_quantity!(Map.get(block, "blocknumber", "0")),
        header: parse_optional_header(Map.get(block, "blockHeader")),
        rlp: parse_bytes!(Map.fetch!(block, "rlp")),
        transactions: Enum.map(Map.get(block, "transactions", []), &parse_transaction/1),
        withdrawals: Enum.map(Map.get(block, "withdrawals", []) || [], &parse_withdrawal/1),
        expect_exception: Map.get(block, "expectException")
      }
    end)
  end

  defp parse_optional_header(nil), do: nil
  defp parse_optional_header(header), do: parse_block_header(header)

  defp parse_block_header(header) do
    %BlockHeader{
      parent_hash: parse_bytes!(Map.fetch!(header, "parentHash")),
      coinbase: parse_address!(Map.fetch!(header, "coinbase")),
      state_root: parse_bytes!(Map.fetch!(header, "stateRoot")),
      transactions_root: parse_bytes!(Map.fetch!(header, "transactionsTrie")),
      receipts_root: parse_bytes!(Map.fetch!(header, "receiptTrie")),
      logs_bloom: parse_bytes!(Map.fetch!(header, "bloom")),
      difficulty: parse_quantity!(Map.fetch!(header, "difficulty")),
      number: parse_quantity!(Map.fetch!(header, "number")),
      gas_limit: parse_quantity!(Map.fetch!(header, "gasLimit")),
      gas_used: parse_quantity!(Map.fetch!(header, "gasUsed")),
      timestamp: parse_quantity!(Map.fetch!(header, "timestamp")),
      extra_data: parse_bytes!(Map.fetch!(header, "extraData")),
      mix_hash: parse_quantity!(Map.fetch!(header, "mixHash")),
      nonce: parse_bytes!(Map.fetch!(header, "nonce")),
      base_fee_per_gas: parse_quantity!(Map.get(header, "baseFeePerGas", "0x0")),
      withdrawals_root: parse_optional_bytes(Map.get(header, "withdrawalsRoot")),
      blob_gas_used: parse_optional_quantity(Map.get(header, "blobGasUsed")),
      excess_blob_gas: parse_optional_quantity(Map.get(header, "excessBlobGas")),
      parent_beacon_block_root: parse_optional_quantity(Map.get(header, "parentBeaconBlockRoot")),
      requests_hash: parse_optional_bytes(Map.get(header, "requestsHash")),
      hash: parse_bytes!(Map.fetch!(header, "hash"))
    }
  end

  defp parse_withdrawal(w) do
    %Withdrawal{
      index: parse_quantity!(Map.fetch!(w, "index")),
      validator_index: parse_quantity!(Map.fetch!(w, "validatorIndex")),
      address: parse_address!(Map.fetch!(w, "address")),
      amount: parse_quantity!(Map.fetch!(w, "amount"))
    }
  end

  defp parse_transaction(tx) do
    type = parse_tx_type(Map.get(tx, "type"))

    %TransactionFields{
      sender: parse_address!(Map.fetch!(tx, "sender")),
      nonce: parse_quantity!(Map.fetch!(tx, "nonce")),
      type: type,
      to: parse_optional_address(Map.get(tx, "to", "")),
      value: parse_quantity!(Map.fetch!(tx, "value")),
      data: parse_bytes!(Map.fetch!(tx, "data")),
      gas_limit: parse_quantity!(Map.fetch!(tx, "gasLimit")),
      gas_price: parse_quantity!(Map.get(tx, "gasPrice", "0x0")),
      max_fee_per_gas: parse_quantity!(Map.get(tx, "maxFeePerGas", "0x0")),
      max_priority_fee_per_gas: parse_quantity!(Map.get(tx, "maxPriorityFeePerGas", "0x0")),
      max_fee_per_blob_gas: parse_quantity!(Map.get(tx, "maxFeePerBlobGas", "0x0")),
      access_list: parse_access_list(Map.get(tx, "accessList", [])),
      blob_hashes: parse_quantity_list(Map.get(tx, "blobVersionedHashes", [])),
      chain_id: parse_quantity!(Map.get(tx, "chainId", "0x1"))
    }
  end

  defp parse_accounts(map) do
    Enum.into(map, %{}, fn {address, payload} ->
      {parse_address!(address),
       %Account{
         balance: parse_quantity!(Map.get(payload, "balance", "0x0")),
         nonce: parse_quantity!(Map.get(payload, "nonce", "0x0")),
         code: parse_bytes!(Map.get(payload, "code", "0x")),
         storage: parse_storage(Map.get(payload, "storage", %{}))
       }}
    end)
  end

  defp parse_storage(storage) do
    Enum.into(storage, %{}, fn {slot, value} ->
      {parse_quantity!(slot), parse_quantity!(value)}
    end)
  end

  defp parse_access_list(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      {parse_address!(Map.fetch!(entry, "address")),
       Enum.map(Map.get(entry, "storageKeys", []), &parse_quantity!/1)}
    end)
  end

  defp parse_quantity_list(values) when is_list(values), do: Enum.map(values, &parse_quantity!/1)

  defp parse_tx_type(nil), do: :legacy
  defp parse_tx_type("0x0"), do: :legacy
  defp parse_tx_type("0x00"), do: :legacy
  defp parse_tx_type("0x1"), do: :eip2930
  defp parse_tx_type("0x01"), do: :eip2930
  defp parse_tx_type("0x2"), do: :eip1559
  defp parse_tx_type("0x02"), do: :eip1559
  defp parse_tx_type("0x3"), do: :eip4844
  defp parse_tx_type("0x03"), do: :eip4844
  defp parse_tx_type("0x4"), do: :eip7702
  defp parse_tx_type("0x04"), do: :eip7702
  defp parse_tx_type(_), do: :legacy

  defp parse_network!("Frontier"), do: :frontier
  defp parse_network!("Homestead"), do: :homestead
  defp parse_network!("EIP150"), do: :tangerine_whistle
  defp parse_network!("EIP158"), do: :spurious_dragon
  defp parse_network!("Byzantium"), do: :byzantium
  defp parse_network!("Constantinople"), do: :constantinople
  defp parse_network!("ConstantinopleFix"), do: :constantinople
  defp parse_network!("Istanbul"), do: :istanbul
  defp parse_network!("Berlin"), do: :berlin
  defp parse_network!("London"), do: :london
  defp parse_network!("Paris"), do: :paris
  defp parse_network!("Merge"), do: :paris
  defp parse_network!("Shanghai"), do: :shanghai
  defp parse_network!("Cancun"), do: :cancun
  defp parse_network!("Prague"), do: :prague
  defp parse_network!(other), do: raise(ArgumentError, "unsupported network #{inspect(other)}")

  defp parse_optional_address(""), do: nil
  defp parse_optional_address("0x"), do: nil
  defp parse_optional_address(value), do: parse_address!(value)

  defp parse_address!(value) do
    value
    |> parse_bytes!()
    |> :binary.decode_unsigned()
  end

  defp parse_optional_bytes(nil), do: nil
  defp parse_optional_bytes(value), do: parse_bytes!(value)

  defp parse_optional_quantity(nil), do: nil
  defp parse_optional_quantity(value), do: parse_quantity!(value)

  defp parse_quantity!("0x"), do: 0
  defp parse_quantity!(""), do: 0

  defp parse_quantity!("0x" <> hex) do
    if hex == "" do
      0
    else
      String.to_integer(hex, 16)
    end
  end

  defp parse_quantity!(value) when is_binary(value), do: String.to_integer(value)
  defp parse_quantity!(value) when is_integer(value), do: value

  defp parse_bytes!("0x" <> hex), do: Base.decode16!(String.upcase(hex), case: :mixed)
  defp parse_bytes!(value) when is_binary(value), do: value
end
