defmodule EEVM.BlockchainTestTest do
  use ExUnit.Case, async: true

  alias EEVM.TestSupport.{
    BlockchainTestCatalog,
    BlockchainTestFixture,
    BlockchainTestRunner
  }

  fixture_paths = BlockchainTestCatalog.fixture_paths()

  for fixture_path <- fixture_paths,
      blockchain_test <- BlockchainTestFixture.load_file!(fixture_path),
      BlockchainTestCatalog.skipped?(fixture_path, blockchain_test.name) == false do
    @tag :blockchain_tests
    test "#{blockchain_test.name} from #{Path.basename(fixture_path)}" do
      assert :ok = BlockchainTestRunner.run_case(unquote(Macro.escape(blockchain_test)))
    end
  end

  describe "EIP-7934 RLP block size limit" do
    # Reuses the smoke fixture's Prague chain; the runner reads only the
    # size of `rlp`, so padding it moves the block across the limit.
    @max_rlp_block_size 8_388_608

    setup do
      [prague_case] =
        "test/fixtures/blockchain_tests/smoke/mergeExample.json"
        |> BlockchainTestFixture.load_file!()
        |> Enum.filter(&(&1.network == :prague))

      %{prague_case: prague_case}
    end

    test "Osaka imports a block at the limit and rejects one byte over", %{prague_case: test} do
      osaka_case = %{test | network: :osaka}

      assert :ok = BlockchainTestRunner.run_case(with_rlp_size(osaka_case, @max_rlp_block_size))

      assert {:error, {:block_failed, 1, :rlp_block_size_exceeded}} =
               BlockchainTestRunner.run_case(with_rlp_size(osaka_case, @max_rlp_block_size + 1))
    end

    test "Prague has no block size limit", %{prague_case: test} do
      assert :ok = BlockchainTestRunner.run_case(with_rlp_size(test, @max_rlp_block_size + 1))
    end
  end

  defp with_rlp_size(test, size) do
    %{test | blocks: Enum.map(test.blocks, &%{&1 | rlp: :binary.copy(<<0>>, size)})}
  end
end
