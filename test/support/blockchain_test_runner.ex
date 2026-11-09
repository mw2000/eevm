defmodule EEVM.TestSupport.BlockchainTestRunner do
  @moduledoc """
  Executes a single BlockchainTest case through the public block path.

  1. Build the pre-state database from the fixture's `pre` map and install
     the system contracts the hardfork mandates (the fixtures' genesis state).
  2. Decode the genesis block and each block from its canonical `rlp` with
     `EEVM.Block.decode/1`, and apply it with `EEVM.Block.execute/4` on top
     of the previous valid block. BLOCKHASH sees the hashes of every block
     applied so far. Transition networks such as `CancunToPragueAtTime15k`
     pick the fork for each block from its header.
  3. After every block, verify the final database matches the fixture's
     `postState`.

  A block with `expectException` must fail to decode or execute; the chain
  then continues from the previous block. A block without one must apply.
  """

  alias EEVM.Block
  alias EEVM.Block.Header
  alias EEVM.Config
  alias EEVM.Database
  alias EEVM.Database.InMemory
  alias EEVM.SystemContracts.{BeaconRoots, BlockHashes}
  alias EEVM.TestSupport.BlockchainTestFixture.{Account, Case}
  alias EEVM.TestSupport.BlockchainTestFixture.Block, as: FixtureBlock

  @spec run_case(Case.t()) :: :ok | {:error, term()}
  def run_case(%Case{} = test) do
    with {:ok, %Block{header: genesis}} <- Block.decode(test.genesis_rlp),
         db = build_pre_state(test.pre, block_config(test, genesis)),
         {:ok, final_db} <- run_blocks(test.blocks, db, genesis, test) do
      verify_post_state(final_db, test.post)
    end
  end

  defp build_pre_state(pre, %Config{} = config) do
    accounts =
      Map.new(pre, fn {addr, %Account{balance: balance, nonce: nonce, code: code}} ->
        {addr, %{balance: balance, nonce: nonce, code: code}}
      end)

    storage =
      Enum.reduce(pre, %{}, fn {addr, %Account{storage: slots}}, acc ->
        if map_size(slots) == 0, do: acc, else: Map.put(acc, addr, slots)
      end)

    [accounts: accounts, storage: storage]
    |> InMemory.new()
    |> BeaconRoots.install_if_enabled(config.hardfork)
    |> BlockHashes.install_if_enabled(config.hardfork)
  end

  defp run_blocks(blocks, db, %Header{} = genesis, test) do
    initial = {db, genesis, %{genesis.number => :binary.decode_unsigned(genesis.hash)}}

    Enum.reduce_while(blocks, {:ok, initial}, fn block, {:ok, chain} ->
      case attempt_block(block, chain, test) do
        {:ok, chain} -> {:cont, {:ok, chain}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, {db, _parent, _hashes}} -> {:ok, db}
      {:error, _} = error -> error
    end
  end

  # `expectException` semantics: a declared exception means the block must
  # be rejected, and the chain continues from the previous block. Without
  # one, any rejection fails the case.
  defp attempt_block(%FixtureBlock{expect_exception: exception} = block, chain, test) do
    case {apply_block(block, chain, test), exception} do
      {{:ok, chain}, nil} -> {:ok, chain}
      {{:error, reason}, nil} -> {:error, {:block_failed, block.block_number, reason}}
      {{:ok, _}, _} -> {:error, {:expected_exception_not_raised, block.block_number, exception}}
      {{:error, _}, _} -> {:ok, chain}
    end
  end

  defp apply_block(%FixtureBlock{rlp: rlp}, {db, parent, hashes}, test) do
    with {:ok, %Block{header: header} = block} <- Block.decode(rlp),
         config = block_config(test, header),
         {:ok, result} <- Block.execute(block, parent, db, config: config, block_hashes: hashes) do
      {:ok,
       {result.post_state_db, header,
        Map.put(hashes, header.number, :binary.decode_unsigned(header.hash))}}
    end
  end

  # Transition fixtures (e.g. `PragueToOsakaAtTime15k`) switch forks mid-chain.
  defp block_config(%Case{transition: nil, network: fork}, _header), do: Config.new(fork)

  defp block_config(%Case{transition: %{from: from, at: at}, network: to}, header) do
    Config.new(if activated?(at, header), do: to, else: from)
  end

  defp activated?({:block, number}, header), do: header.number >= number
  defp activated?({:timestamp, timestamp}, header), do: header.timestamp >= timestamp
  defp activated?(:merge, header), do: header.difficulty == 0

  defp verify_post_state(db, post) do
    Enum.find_value(post, :ok, fn {addr, %Account{} = expected} ->
      case account_diff(db, addr, expected) do
        nil -> nil
        diff -> {:error, {:post_state_mismatch, addr, diff}}
      end
    end)
  end

  defp account_diff(db, addr, %Account{} = expected) do
    actual_balance = Database.get_balance(db, addr)
    actual_nonce = Database.get_nonce(db, addr)
    actual_code = Database.get_code(db, addr)

    cond do
      actual_balance != expected.balance ->
        {:balance, expected: expected.balance, actual: actual_balance}

      actual_nonce != expected.nonce ->
        {:nonce, expected: expected.nonce, actual: actual_nonce}

      actual_code != expected.code ->
        {:code, expected: expected.code, actual: actual_code}

      storage_mismatch?(db, addr, expected.storage) ->
        {:storage, expected: expected.storage, actual: read_storage(db, addr, expected.storage)}

      true ->
        nil
    end
  end

  defp storage_mismatch?(db, addr, expected_storage) do
    Enum.any?(expected_storage, fn {slot, expected_value} ->
      Database.storage_load(db, addr, slot) != expected_value
    end)
  end

  defp read_storage(db, addr, expected_storage) do
    Map.new(expected_storage, fn {slot, _} -> {slot, Database.storage_load(db, addr, slot)} end)
  end
end
