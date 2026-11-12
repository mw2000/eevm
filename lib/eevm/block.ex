defmodule EEVM.Block do
  @moduledoc """
  A full execution-layer block — header, transactions, ommers, and
  withdrawals — and the public path to build, encode, validate, and execute
  one.

  | Field | Description |
  |-------|-------------|
  | `header` | The `EEVM.Block.Header` |
  | `transactions` | Signed transactions (see `EEVM.Transaction`), in order |
  | `ommers` | Uncle headers; always empty after the Merge |
  | `withdrawals` | `EEVM.Block.Withdrawal`s from Shanghai on, `nil` before |

  - `decode/1` and `encode/1` convert to and from canonical RLP.
  - `validate/3` runs every check that needs no state: the EIP-7934 size
    limit, `EEVM.Block.HeaderValidator` against the parent, and the body
    against the header's commitments.
  - `execute/4` validates the block, applies it to a database (system calls,
    each transaction through `EEVM.Handler`, withdrawals, EIP-7685 requests),
    and checks the header's `gas_used`, `logs_bloom`, `receipts_root`,
    `state_root`, and `requests_hash` against the result.
  - `build/4` produces a child block of a parent: it derives the header,
    executes the transactions, fills in every commitment, and hashes it.

  Options follow `EEVM.Handler.execute/4`: a full `:config` (hardfork, chain
  id, custom precompiles) or the `:hardfork` shorthand (default `:cancun`);
  `:chain_id` is deprecated in favour of the config's. `:block_hashes` maps
  recent block numbers to their 32-byte hashes for BLOCKHASH. From Prague,
  `:deposit_contract_address` names the chain's EIP-6110 deposit contract
  (default: mainnet's, `EEVM.Block.Requests.mainnet_deposit_contract/0`).
  `tracer: true` traces every transaction: `result.trace` is a list with one
  `EEVM.Tracer` per transaction, in block order (like geth's
  `debug_traceBlock`), so transaction boundaries stay visible.

  Errors are `{:error, reason}` with the reasons catalogued in `EEVM.Error`
  as `t:EEVM.Error.block_error/0`.

  ## Example

      iex> alias EEVM.Block
      iex> parent = EEVM.Block.Header.new(gas_limit: 30_000_000, base_fee_per_gas: 7, hash: <<1::256>>)
      iex> db = EEVM.Database.InMemory.new()
      iex> {:ok, block, _result} = Block.build(parent, [], db, hardfork: :shanghai, timestamp: 12)
      iex> {:ok, decoded} = block |> Block.encode() |> Block.decode()
      iex> decoded == block
      true
      iex> {:ok, result} = Block.execute(decoded, parent, db, hardfork: :shanghai)
      iex> result.gas_used
      0

  Not covered: ommer (uncle) validation and rewards, and fork transitions
  inside a chain.
  """

  alias EEVM.Block.{Header, HeaderValidator, Processor, Requests, Result, Withdrawal}
  alias EEVM.{BlockEnv, Config, Database, HardforkConfig, StateRoot, TransactionResult}
  alias EEVM.Crypto.Keccak
  alias EEVM.Gas.Blob, as: BlobGas
  alias EEVM.Handler
  alias EEVM.Handler.Validation
  alias EEVM.MPT.Trie
  alias EEVM.SystemContracts.{BeaconRoots, BlockHashes}
  alias EEVM.Transaction.{AccessList, Blob, Envelope, FeeMarket, Legacy, SetCode}
  import EEVM.HardforkConfig, only: [enabled?: 2]

  # EIP-7934: MAX_BLOCK_SIZE (10 MiB) minus a 2 MiB beacon-block SAFETY_MARGIN.
  @max_rlp_block_size 10_485_760 - 2_097_152

  # Proof-of-work block reward (Yellow Paper section 11.3), cut by EIP-649
  # and EIP-1234; none from Paris (EIP-3675).
  @frontier_block_reward 5_000_000_000_000_000_000
  @byzantium_block_reward 3_000_000_000_000_000_000
  @constantinople_block_reward 2_000_000_000_000_000_000

  @type transaction :: Legacy.t() | AccessList.t() | FeeMarket.t() | Blob.t() | SetCode.t()

  @type t :: %__MODULE__{
          header: Header.t(),
          transactions: [transaction()],
          ommers: [Header.t()],
          withdrawals: [Withdrawal.t()] | nil
        }

  defstruct header: %Header{}, transactions: [], ommers: [], withdrawals: nil

  @type opts :: [
          hardfork: HardforkConfig.spec_id(),
          config: Config.t(),
          chain_id: non_neg_integer(),
          block_hashes: %{non_neg_integer() => <<_::256>>},
          deposit_contract_address: non_neg_integer(),
          tracer: boolean()
        ]

  @type build_opts :: [
          hardfork: HardforkConfig.spec_id(),
          config: Config.t(),
          chain_id: non_neg_integer(),
          block_hashes: %{non_neg_integer() => <<_::256>>},
          deposit_contract_address: non_neg_integer(),
          tracer: boolean(),
          timestamp: non_neg_integer(),
          coinbase: non_neg_integer(),
          gas_limit: non_neg_integer(),
          prev_randao: non_neg_integer(),
          extra_data: binary(),
          parent_beacon_block_root: <<_::256>> | non_neg_integer(),
          withdrawals: [Withdrawal.t()]
        ]

  @doc "Returns `MAX_RLP_BLOCK_SIZE`, the largest encoded block valid from Osaka (EIP-7934)."
  @spec max_rlp_block_size() :: pos_integer()
  def max_rlp_block_size, do: @max_rlp_block_size

  @doc """
  Encodes `block` as canonical RLP:
  `[header, transactions, ommers]`, plus `withdrawals` when it isn't `nil`.

  Legacy transactions are embedded as RLP lists and typed transactions as
  their EIP-2718 envelope bytes.
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = block) do
    fields = [
      Header.to_rlp(block.header),
      Enum.map(block.transactions, &transaction_to_rlp/1),
      Enum.map(block.ommers, &Header.to_rlp/1)
    ]

    case block.withdrawals do
      nil -> ExRLP.encode(fields)
      withdrawals -> ExRLP.encode(fields ++ [Enum.map(withdrawals, &withdrawal_to_rlp/1)])
    end
  end

  @doc """
  Decodes a canonical RLP block. The header's `hash` is set from its bytes.

  Returns `{:error, :invalid_block_encoding}` when the bytes aren't a
  canonical encoding of a block (malformed RLP, a wrong-sized field, a
  non-canonical integer, a withdrawal field over 64 bits, or an undecodable
  transaction).
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid_block_encoding}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, fields} <- Header.safe_rlp_decode(bytes),
         {:ok, block} <- from_rlp(fields) do
      if encode(block) == bytes, do: {:ok, block}, else: {:error, :invalid_block_encoding}
    end
  end

  @doc """
  Checks `block` against `parent` without touching state, in this order:

  1. The config sets no simulation switch (`EEVM.Config.simulation?/1`),
     else `:simulation_config`: blocks never run with relaxed rules.
  2. From Osaka, the encoded block is at most `max_rlp_block_size/0` bytes
     (EIP-7934), else `:rlp_block_size_exceeded`.
  3. The header is a valid child of `parent` (`EEVM.Block.HeaderValidator`;
     the checks and their errors are listed in `EEVM.Error`).
  4. The body matches the header: `ommers_hash`, `transactions_root`,
     `withdrawals_root` (withdrawals are present exactly from Shanghai), and
     from Cancun the total blob gas of the transactions equals
     `blob_gas_used`.
  """
  @spec validate(t(), Header.t(), opts()) :: :ok | {:error, EEVM.Error.block_error()}
  def validate(%__MODULE__{} = block, %Header{} = parent, opts \\ []) do
    config = Validation.resolve_config(opts)
    hardfork = config.hardfork

    with :ok <- check_consensus_config(config),
         :ok <- check_size(block, hardfork),
         :ok <- HeaderValidator.validate(block.header, parent, hardfork),
         :ok <- check_ommers(block),
         :ok <- check_transactions_root(block),
         :ok <- check_withdrawals(block, hardfork) do
      check_blob_gas_used(block, hardfork)
    end
  end

  @doc """
  Validates `block` with `validate/3`, then applies it to `db`: the EIP-4788
  and EIP-2935 system calls, each transaction through `EEVM.Handler`, the
  EIP-4895 withdrawals, and from Prague the EIP-7685 requests (EIP-6110
  deposits, then the EIP-7002 and EIP-7251 system calls; see
  `EEVM.Block.Requests`). Finally checks the header's `gas_used`,
  `logs_bloom`, `receipts_root`, `state_root`, and `requests_hash` against
  the result.

  With `tracer: true`, each transaction is traced and `result.trace` lists
  one `EEVM.Tracer` per transaction, in block order; system calls are not
  traced.

  Returns `{:ok, %EEVM.Block.Result{}}` whose `db` is the state after the
  block and whose `requests` are the block's requests. A
  transaction that `EEVM.Handler` rejects, or whose gas limit exceeds the gas
  left in the block, fails the block with
  `{:error, {:tx_failed, index, reason}}`; a request that can't be collected
  fails it with that reason.
  """
  @spec execute(t(), Header.t(), Database.t(), opts()) ::
          {:ok, Result.t()} | {:error, EEVM.Error.block_error()}
  def execute(%__MODULE__{} = block, %Header{} = parent, %Database{} = db, opts \\ []) do
    Database.catch_read_errors(fn ->
      with :ok <- validate(block, parent, opts),
           {:ok, result} <- run(block, db, Validation.resolve_config(opts), opts),
           {:ok, result} <- check_result(result, block.header) do
        finish(result)
      end
    end)
  end

  @doc """
  Builds the child of `parent` holding `transactions` (signed wire
  transactions, in order) and executes it on `db`.

  The header takes `number`, `parent_hash`, the EIP-1559 base fee, and the
  EIP-4844 excess blob gas from `parent`, and every commitment from the
  execution result; `hash` is computed. Fork-dependent fields are set exactly
  for the forks that define them.

  Options are those of `execute/4` plus header attributes: `:timestamp`
  (default: 12 seconds, one mainnet slot, after the parent's), `:coinbase`,
  `:gas_limit` (default: the parent's),
  `:prev_randao`, `:extra_data`, `:parent_beacon_block_root`, and
  `:withdrawals` (from Shanghai).

  Returns `{:ok, block, result}` or the first error `execute/4` would report,
  including `{:error, :simulation_config}` for a config with a simulation
  switch set.

  From Prague the state must hold the EIP-7002 and EIP-7251 request contracts,
  as on mainnet; give a new chain its system contracts with
  `EEVM.SystemContracts.genesis_accounts/1`.
  """
  @spec build(Header.t(), [transaction()], Database.t(), build_opts()) ::
          {:ok, t(), Result.t()} | {:error, EEVM.Error.block_error()}
  def build(%Header{} = parent, transactions, %Database{} = db, opts)
      when is_list(transactions) and is_list(opts) do
    config = Validation.resolve_config(opts)
    hardfork = config.hardfork
    withdrawals = if enabled?(hardfork, :eip_4895), do: Keyword.get(opts, :withdrawals, [])

    header =
      Header.new(
        parent_hash: parent.hash,
        number: parent.number + 1,
        timestamp: Keyword.get(opts, :timestamp, parent.timestamp + 12),
        coinbase: Keyword.get(opts, :coinbase, 0),
        gas_limit: Keyword.get(opts, :gas_limit, parent.gas_limit),
        prev_randao: Keyword.get(opts, :prev_randao, 0),
        extra_data: Keyword.get(opts, :extra_data, <<>>),
        base_fee_per_gas:
          if(enabled?(hardfork, :eip_1559), do: Header.calc_base_fee_per_gas(parent)),
        withdrawals_root: if(withdrawals, do: withdrawals_root(withdrawals)),
        blob_gas_used: if(enabled?(hardfork, :eip_4844), do: total_blob_gas(transactions)),
        excess_blob_gas:
          if(enabled?(hardfork, :eip_4844), do: BlobGas.calc_excess_blob_gas(parent, hardfork)),
        parent_beacon_block_root:
          if(enabled?(hardfork, :eip_4788),
            do: Keyword.get(opts, :parent_beacon_block_root, <<0::256>>)
          ),
        requests_hash: nil
      )

    block = %__MODULE__{header: header, transactions: transactions, withdrawals: withdrawals}

    Database.catch_read_errors(fn ->
      with :ok <- check_consensus_config(config),
           {:ok, result} <- run(block, db, config, opts),
           {:ok, result} <- finish(result) do
        {:ok, seal(block, header, result), result}
      end
    end)
  end

  # The simulation switches relax transaction rules for tooling; a block that
  # ran under them would not be a valid Ethereum block.
  defp check_consensus_config(config) do
    if Config.simulation?(config), do: {:error, :simulation_config}, else: :ok
  end

  defp seal(block, header, result) do
    header = %{
      header
      | state_root: result.state_root,
        transactions_root: result.transactions_root,
        receipts_root: result.receipts_root,
        logs_bloom: result.logs_bloom,
        gas_used: result.gas_used,
        requests_hash: result.requests && Requests.hash(result.requests)
    }

    %{block | header: %{header | hash: Header.compute_hash(header)}}
  end

  # The block's writes become `changes`, committed once for the whole block
  # when the backend supports it.
  defp finish(%Result{db: db} = result) do
    with {:ok, committed} <- Database.commit_if_supported(db) do
      {:ok, %{result | db: committed, post_state_db: committed, changes: Database.changes(db)}}
    end
  end

  # ---------------------------------------------------------------------------
  # Execution
  # ---------------------------------------------------------------------------

  defp run(%__MODULE__{header: header} = block, db, %Config{} = config, opts) do
    Processor.process_block(header, block.transactions, db,
      tx_executor: tx_executor(config, Keyword.get(opts, :tracer, false)),
      system_calls: system_calls(header, config.hardfork),
      rewards: rewards(block, config.hardfork),
      withdrawals: block.withdrawals || [],
      block_context: block_context(header, config, opts),
      requests: requests(config, opts)
    )
  end

  defp requests(%Config{} = config, opts) do
    if enabled?(config.hardfork, :eip_7685) do
      deposit_contract =
        Keyword.get(opts, :deposit_contract_address, Requests.mainnet_deposit_contract())

      &Requests.collect(&1, &2, &3, config, deposit_contract)
    end
  end

  defp tx_executor(config, tracer?) do
    fn tx, block_ctx, db ->
      case Handler.execute(tx, block_ctx, db, config: config, tracer: tracer?, commit: false) do
        {:ok, %TransactionResult{} = result} ->
          {:ok,
           %{
             status: result.receipt.status,
             gas_used: result.gas_used,
             logs: result.logs,
             db: result.db,
             tx_type: result.receipt.tx_type,
             contract_address: result.contract_address,
             trace: result.trace
           }
           |> put_receipt_state_root(config.hardfork)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp block_context(%Header{} = header, %Config{} = config, opts) do
    BlockEnv.from_header(header,
      config: config,
      block_hashes: Keyword.get(opts, :block_hashes, %{})
    )
  end

  # Before Byzantium a receipt commits to the state after its transaction
  # instead of a status code (EIP-658).
  defp put_receipt_state_root(tx_result, hardfork) do
    if enabled?(hardfork, :eip_658) do
      tx_result
    else
      {state_root, db} = StateRoot.update(tx_result.db)
      %{tx_result | db: db} |> Map.put(:state_root, state_root)
    end
  end

  # Before Paris the miner earns the block reward plus 1/32 of it per ommer,
  # and each ommer's miner earns (8 + ommer number - block number) / 8 of it
  # (Yellow Paper section 11.3).
  defp rewards(%__MODULE__{header: header, ommers: ommers}, hardfork) do
    reward = block_reward(hardfork)

    if reward == 0 do
      []
    else
      miner = {header.coinbase, reward + div(reward, 32) * length(ommers)}

      ommer_rewards =
        Enum.map(ommers, fn ommer ->
          {ommer.coinbase, div((8 + ommer.number - header.number) * reward, 8)}
        end)

      [miner | ommer_rewards]
    end
  end

  defp block_reward(hardfork) do
    cond do
      enabled?(hardfork, :eip_3675) -> 0
      enabled?(hardfork, :eip_1234) -> @constantinople_block_reward
      enabled?(hardfork, :eip_649) -> @byzantium_block_reward
      true -> @frontier_block_reward
    end
  end

  # EIP-4788 then EIP-2935, both before any transaction.
  defp system_calls(%Header{} = header, hardfork) do
    beacon_root = fn db, ctx ->
      unwrap_system_call(
        BeaconRoots.commit(db, ctx, header.parent_beacon_block_root || <<0::256>>)
      )
    end

    block_hash = fn db, ctx ->
      unwrap_system_call(BlockHashes.commit(db, ctx, header.parent_hash))
    end

    for {true, call} <- [
          {enabled?(hardfork, :eip_4788), beacon_root},
          {enabled?(hardfork, :eip_2935), block_hash}
        ],
        do: call
  end

  # The canonical system contracts never revert; if one does, the block keeps
  # the state from before the call, as clients do.
  defp unwrap_system_call({:ok, %Database{} = db}), do: db
  defp unwrap_system_call({:error, _reason, %Database{} = db}), do: db

  defp check_result(%Result{} = result, %Header{} = header) do
    cond do
      result.gas_used != header.gas_used ->
        {:error, :invalid_gas_used}

      result.logs_bloom != header.logs_bloom ->
        {:error, :invalid_logs_bloom}

      result.receipts_root != header.receipts_root ->
        {:error, :invalid_receipts_root}

      result.state_root != header.state_root ->
        {:error, :invalid_state_root}

      result.requests && Requests.hash(result.requests) != header.requests_hash ->
        {:error, :invalid_requests_hash}

      true ->
        {:ok, result}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp check_size(block, hardfork) do
    if enabled?(hardfork, :eip_7934) and byte_size(encode(block)) > @max_rlp_block_size,
      do: {:error, :rlp_block_size_exceeded},
      else: :ok
  end

  defp check_ommers(%__MODULE__{ommers: ommers, header: header}) do
    hash = ommers |> Enum.map(&Header.to_rlp/1) |> ExRLP.encode() |> Keccak.hash_256()
    if hash == header.ommers_hash, do: :ok, else: {:error, :invalid_ommers_hash}
  end

  defp check_transactions_root(%__MODULE__{transactions: txs, header: header}) do
    if transactions_root(txs) == header.transactions_root,
      do: :ok,
      else: {:error, :invalid_transactions_root}
  end

  defp check_withdrawals(%__MODULE__{withdrawals: withdrawals, header: header}, hardfork) do
    case {enabled?(hardfork, :eip_4895), withdrawals} do
      {false, nil} ->
        :ok

      {true, list} when is_list(list) ->
        if withdrawals_root(list) == header.withdrawals_root,
          do: :ok,
          else: {:error, :invalid_withdrawals_root}

      _ ->
        {:error, :invalid_withdrawals_root}
    end
  end

  defp check_blob_gas_used(%__MODULE__{transactions: txs, header: header}, hardfork) do
    if not enabled?(hardfork, :eip_4844) or total_blob_gas(txs) == header.blob_gas_used,
      do: :ok,
      else: {:error, :invalid_blob_gas_used}
  end

  defp transactions_root(transactions) do
    transactions
    |> Enum.with_index()
    |> Enum.map(fn {tx, index} -> {ExRLP.encode(index), Envelope.encode(tx)} end)
    |> Trie.root_hash()
  end

  defp withdrawals_root(withdrawals) do
    withdrawals
    |> Enum.with_index()
    |> Enum.map(fn {w, index} -> {ExRLP.encode(index), ExRLP.encode(withdrawal_to_rlp(w))} end)
    |> Trie.root_hash()
  end

  defp total_blob_gas(transactions) do
    Enum.reduce(transactions, 0, fn
      %Blob{blob_versioned_hashes: hashes}, acc -> acc + length(hashes) * BlobGas.gas_per_blob()
      _tx, acc -> acc
    end)
  end

  # ---------------------------------------------------------------------------
  # RLP
  # ---------------------------------------------------------------------------

  defp from_rlp([header, txs, ommers | rest]) when is_list(txs) and is_list(ommers) do
    with {:ok, header} <- Header.from_rlp(header),
         {:ok, txs} <- map_ok(txs, &transaction_from_rlp/1),
         {:ok, ommers} <- map_ok(ommers, &Header.from_rlp/1),
         {:ok, withdrawals} <- withdrawals_from_rlp(rest) do
      {:ok,
       %__MODULE__{header: header, transactions: txs, ommers: ommers, withdrawals: withdrawals}}
    end
  end

  defp from_rlp(_), do: {:error, :invalid_block_encoding}

  defp withdrawals_from_rlp([]), do: {:ok, nil}
  defp withdrawals_from_rlp([list]) when is_list(list), do: map_ok(list, &withdrawal_from_rlp/1)
  defp withdrawals_from_rlp(_), do: {:error, :invalid_block_encoding}

  # EIP-4895: index, validator_index, and amount are uint64; the address is 20 bytes.
  defp withdrawal_from_rlp([index, validator_index, <<address::unsigned-big-160>>, amount]) do
    with {:ok, index} <- decode_uint64(index),
         {:ok, validator_index} <- decode_uint64(validator_index),
         {:ok, amount} <- decode_uint64(amount) do
      {:ok,
       %Withdrawal{
         index: index,
         validator_index: validator_index,
         address: address,
         amount: amount
       }}
    end
  end

  defp withdrawal_from_rlp(_), do: {:error, :invalid_block_encoding}

  defp decode_uint64(value) when is_binary(value) and byte_size(value) <= 8,
    do: Header.decode_uint(value)

  defp decode_uint64(_), do: {:error, :invalid_block_encoding}

  defp withdrawal_to_rlp(%Withdrawal{} = w) do
    [
      Header.encode_uint(w.index),
      Header.encode_uint(w.validator_index),
      <<w.address::unsigned-big-160>>,
      Header.encode_uint(w.amount)
    ]
  end

  # Legacy transactions sit in the block as RLP lists, typed ones as envelope bytes.
  defp transaction_from_rlp(fields) when is_list(fields),
    do: fields |> ExRLP.encode() |> decode_transaction()

  defp transaction_from_rlp(<<type, _::binary>> = envelope) when type < 0x80,
    do: decode_transaction(envelope)

  defp transaction_from_rlp(_), do: {:error, :invalid_block_encoding}

  defp decode_transaction(bytes) do
    case Envelope.decode(bytes) do
      {:ok, tx} -> {:ok, tx}
      {:error, _} -> {:error, :invalid_block_encoding}
    end
  rescue
    _ -> {:error, :invalid_block_encoding}
  end

  defp transaction_to_rlp(%Legacy{} = tx), do: tx |> Envelope.encode() |> ExRLP.decode()
  defp transaction_to_rlp(tx), do: Envelope.encode(tx)

  defp map_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
