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
  3. Verify that the chain head is the fixture's `lastblockhash` and that the
     state after it matches its `postState`.

  Each block applies on top of the block its `parent_hash` names, so fixtures
  with side chains (a reorg to a heavier chain) build every branch. The head
  follows geth's fork choice: before the Merge, the block with the highest
  total difficulty (a tie keeps the current head); after it, the newest
  block. A block with `expectException` must fail to decode or execute and
  leaves the known blocks unchanged. A block without one must apply, and the
  hash re-computed from its decoded header fields must match its
  `blockHeader.hash`, as must the genesis block's (geth's runner checks the
  same). `EEVM.Block.decode/1` hashes the raw header bytes, so only the
  re-computed hash catches a field that decodes or re-encodes wrongly.
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
         :ok <- verify_hash(:genesis, genesis, test.genesis_hash),
         db = build_pre_state(test.pre, block_config(test, genesis, 0)),
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

  # `known` maps each applied block's hash to the state after it, its header,
  # the BLOCKHASH window of its own ancestry, and its total difficulty.
  defp run_blocks(blocks, db, %Header{} = genesis, test) do
    known = %{
      genesis.hash =>
        {db, genesis, %{genesis.number => :binary.decode_unsigned(genesis.hash)},
         genesis.difficulty}
    }

    Enum.reduce_while(blocks, {:ok, known, genesis.hash}, fn block, {:ok, known, head} ->
      case attempt_block(block, known, test) do
        {:ok, ^known} -> {:cont, {:ok, known, head}}
        {:ok, known, hash} -> {:cont, {:ok, known, fork_choice(known, head, hash)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, known, head} when test.last_block_hash in [nil, head] ->
        {db, _header, _hashes, _td} = Map.fetch!(known, head)
        {:ok, db}

      {:ok, _known, head} ->
        {:error, {:last_block_hash_mismatch, expected: test.last_block_hash, actual: head}}

      {:error, _} = error ->
        error
    end
  end

  # geth's `ForkChoice.ReorgNeeded`: a post-Merge block always becomes the
  # head; before it, only a heavier chain does. (geth also breaks some ties,
  # which no fixture exercises.)
  defp fork_choice(known, head, hash) do
    {_, _, _, head_td} = Map.fetch!(known, head)
    {_, %Header{difficulty: difficulty}, _, td} = Map.fetch!(known, hash)
    if difficulty == 0 or td > head_td, do: hash, else: head
  end

  defp verify_hash(block_number, %Header{} = header, expected) do
    case Header.compute_hash(header) do
      ^expected -> :ok
      actual -> {:error, {:block_hash_mismatch, block_number, expected: expected, actual: actual}}
    end
  end

  # `expectException` semantics: a declared exception means the block must
  # be rejected, and the chain continues from the previous block. Without
  # one, any rejection fails the case.
  defp attempt_block(%FixtureBlock{expect_exception: exception} = block, known, test) do
    case {apply_block(block, known, test), exception} do
      {{:ok, {_db, header, _hashes, _td} = entry}, nil} ->
        with :ok <- verify_hash(block.block_number, header, block.hash),
             do: {:ok, Map.put(known, header.hash, entry), header.hash}

      {{:error, reason}, nil} ->
        {:error, {:block_failed, block.block_number, reason}}

      {{:ok, _}, _} ->
        {:error, {:expected_exception_not_raised, block.block_number, exception}}

      {{:error, _}, _} ->
        {:ok, known}
    end
  end

  defp apply_block(%FixtureBlock{rlp: rlp}, known, test) do
    with {:ok, %Block{header: header} = block} <- Block.decode(rlp),
         {:ok, {db, parent, hashes, parent_td}} <- fetch_parent(known, header),
         config = block_config(test, header, parent_td),
         {:ok, result} <- Block.execute(block, parent, db, config: config, block_hashes: hashes) do
      {:ok,
       {result.db, header, Map.put(hashes, header.number, :binary.decode_unsigned(header.hash)),
        parent_td + header.difficulty}}
    end
  end

  defp fetch_parent(known, %Header{parent_hash: parent_hash}) do
    case Map.fetch(known, parent_hash) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :unknown_parent}
    end
  end

  # Transition fixtures (e.g. `PragueToOsakaAtTime15k`) switch forks mid-chain.
  defp block_config(%Case{transition: nil, network: fork}, _header, _parent_td),
    do: Config.new(fork)

  defp block_config(%Case{transition: %{from: from, at: at}, network: to}, header, parent_td) do
    Config.new(if activated?(at, header, parent_td), do: to, else: from)
  end

  defp activated?({:block, number}, header, _parent_td), do: header.number >= number
  defp activated?({:timestamp, timestamp}, header, _parent_td), do: header.timestamp >= timestamp
  defp activated?({:total_difficulty, ttd}, _header, parent_td), do: parent_td >= ttd

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
