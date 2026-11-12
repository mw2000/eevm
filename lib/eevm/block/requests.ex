defmodule EEVM.Block.Requests do
  @moduledoc """
  EIP-7685 execution-layer requests: the typed messages a block passes to the
  consensus layer from Prague on, and the header's `requests_hash` that
  commits to them.

  A request is a type byte followed by its payload. A block's requests are,
  in type order and leaving out every type whose payload is empty:

  | Type | EIP | Payload |
  |------|-----|---------|
  | `0x00` | EIP-6110 | Every `DepositEvent` the deposit contract logged in the block's receipts, each as `pubkey ++ withdrawal_credentials ++ amount ++ signature ++ index` |
  | `0x01` | EIP-7002 | The output of the end-of-block system call to the withdrawal request contract `0x00000961Ef480Eb55e80D19ad83579A64c007002` |
  | `0x02` | EIP-7251 | The output of the end-of-block system call to the consolidation request contract `0x0000BBdDc7CE488642fb579F8B00f3a590007251` |

  `EEVM.Block.execute/4` collects them after the block's withdrawals, returns
  them as `EEVM.Block.Result` `requests`, and checks the header's
  `requests_hash` against `hash/1`; `EEVM.Block.build/4` fills it in.
  """

  alias EEVM.Block.Receipt
  alias EEVM.{BlockEnv, Config, Database, HardforkConfig, Interpreter, TxEnv}
  alias EEVM.Context.Contract
  alias EEVM.Crypto.SHA256
  alias EEVM.Interpreter.MachineState
  require EEVM.HardforkConfig

  @typedoc "A type byte followed by the request payload."
  @type request :: binary()

  @typedoc "Why request collection failed; each makes the block invalid."
  @type error ::
          :invalid_deposit_event_layout | :system_contract_empty | :system_contract_call_failed

  # EIP-6110: mainnet deposit contract and keccak256("DepositEvent(bytes,bytes,bytes,bytes,bytes)").
  @mainnet_deposit_contract 0x00000000219AB540356CBB839CBE05303D7705FA
  @deposit_event_topic 0x649BBC62D0E31342AFEA4E5CD82D4049E7E1EE912FC0889AA790803BE39038C5

  # EIP-7002 and EIP-7251 predeploys, called by SYSTEM_ADDRESS with
  # SYSTEM_TRANSACTION_GAS like the EIP-4788 and EIP-2935 system calls.
  @withdrawal_request_contract 0x00000961EF480EB55E80D19AD83579A64C007002
  @consolidation_request_contract 0x0000BBDDC7CE488642FB579F8B00F3A590007251
  @system_address 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE
  @system_call_gas 30_000_000

  @doc "Returns the mainnet EIP-6110 deposit contract address, the default `:deposit_contract_address`."
  @spec mainnet_deposit_contract() :: non_neg_integer()
  def mainnet_deposit_contract, do: @mainnet_deposit_contract

  @doc """
  Returns the EIP-7685 `requests_hash` of `requests`:
  `sha256(sha256(request_0) ++ sha256(request_1) ++ ...)`.

  ## Example

      iex> EEVM.Block.Requests.hash([]) |> EEVM.hex()
      "0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  """
  @spec hash([request()]) :: <<_::256>>
  def hash(requests) when is_list(requests) do
    requests
    |> Enum.map(&SHA256.hash/1)
    |> IO.iodata_to_binary()
    |> SHA256.hash()
  end

  @doc """
  Collects a block's requests once its transactions and withdrawals have
  been applied to `db`.

  Deposits are read from `receipts` (logs of `deposit_contract` whose first
  topic is the `DepositEvent` signature). The withdrawal and consolidation
  request contracts are then called in that order, and their storage changes
  are kept in the returned database.

  Returns `{:ok, requests, db}`, or `{:error, reason}` when a deposit log
  isn't laid out as the EIP-6110 `DepositEvent`
  (`:invalid_deposit_event_layout`), a request contract has no code
  (`:system_contract_empty`), or its call fails
  (`:system_contract_call_failed`). Each makes the block invalid.
  """
  @spec collect(Database.t(), BlockEnv.t(), [Receipt.t()], Config.t(), non_neg_integer()) ::
          {:ok, [request()], Database.t()} | {:error, error()}
  def collect(
        %Database{} = db,
        %BlockEnv{} = block,
        receipts,
        %Config{} = config,
        deposit_contract
      ) do
    withdrawals? = HardforkConfig.enabled?(config.hardfork, :eip_7002)
    consolidations? = HardforkConfig.enabled?(config.hardfork, :eip_7251)

    with {:ok, deposits} <- deposits(receipts, deposit_contract, config.hardfork),
         {:ok, withdrawals, db} <-
           system_call(withdrawals?, db, block, config, @withdrawal_request_contract),
         {:ok, consolidations, db} <-
           system_call(consolidations?, db, block, config, @consolidation_request_contract) do
      requests =
        for {type, payload} <- [{0x00, deposits}, {0x01, withdrawals}, {0x02, consolidations}],
            payload != <<>>,
            do: <<type, payload::binary>>

      {:ok, requests, db}
    end
  end

  # EIP-6110: deposit requests come from the deposit contract's logs, in
  # receipt and log order.
  defp deposits(receipts, deposit_contract, hardfork) do
    if HardforkConfig.enabled?(hardfork, :eip_6110) do
      receipts
      |> Enum.flat_map(& &1.logs)
      |> Enum.filter(
        &match?(%{address: ^deposit_contract, topics: [@deposit_event_topic | _]}, &1)
      )
      |> Enum.reduce_while({:ok, <<>>}, fn %{data: data}, {:ok, acc} ->
        case deposit_data(data) do
          {:ok, deposit} -> {:cont, {:ok, acc <> deposit}}
          error -> {:halt, error}
        end
      end)
    else
      {:ok, <<>>}
    end
  end

  # The ABI encoding of `DepositEvent(pubkey, withdrawal_credentials, amount,
  # signature, index)`: five head offsets, then each field's length and its
  # right-padded bytes. EIP-6110 requires exactly this 576-byte layout.
  defp deposit_data(
         <<160::256, 256::256, 320::256, 384::256, 512::256, 48::256, pubkey::binary-48,
           _::binary-16, 32::256, credentials::binary-32, 8::256, amount::binary-8, _::binary-24,
           96::256, signature::binary-96, 8::256, index::binary-8, _::binary-24>>
       ),
       do: {:ok, pubkey <> credentials <> amount <> signature <> index}

  defp deposit_data(_), do: {:error, :invalid_deposit_event_layout}

  # A checked system call (Prague `process_checked_system_transaction`): the
  # contract must have code and the call must succeed, or the block is
  # invalid. Like a transaction it starts with no warm addresses.
  defp system_call(enabled?, db, block, config, address) do
    cond do
      not enabled? ->
        {:ok, <<>>, db}

      Database.get_code(db, address) == <<>> ->
        {:error, :system_contract_empty}

      true ->
        final_state =
          db
          |> Database.get_code(address)
          |> MachineState.new(
            db: db,
            block: block,
            config: config,
            tx: %TxEnv{origin: @system_address, gas_price: block.base_fee},
            contract: %Contract{address: address, caller: @system_address},
            gas: @system_call_gas,
            accessed_addresses: MapSet.new()
          )
          |> Interpreter.run_loop()

        case final_state.status do
          :stopped -> {:ok, final_state.frame.return_data, final_state.db}
          _failed -> {:error, :system_contract_call_failed}
        end
    end
  end
end
