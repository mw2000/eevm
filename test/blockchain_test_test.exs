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
    test BlockchainTestCatalog.test_name(fixture_path, blockchain_test.name) do
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

  describe "fixture blocks that fail to decode" do
    setup do
      [prague_case] =
        "test/fixtures/blockchain_tests/smoke/mergeExample.json"
        |> BlockchainTestFixture.load_file!()
        |> Enum.filter(&(&1.network == :prague))

      undecodable = %{hd(prague_case.blocks) | header: nil, decode_error: "bad hex"}
      %{prague_case: prague_case, undecodable: undecodable}
    end

    test "count as the expected rejection when the block expects an exception", ctx do
      block = %{ctx.undecodable | expect_exception: "BlockException.RLP_STRUCTURES_ENCODING"}

      assert :ok = BlockchainTestRunner.run_case(%{ctx.prague_case | blocks: [block], post: %{}})
    end

    test "fail the case when the block was meant to be valid", ctx do
      assert {:error, {:block_failed, 1, {:invalid_block_encoding, "bad hex"}}} =
               BlockchainTestRunner.run_case(%{ctx.prague_case | blocks: [ctx.undecodable]})
    end
  end

  test "generated test names stay under ExUnit's limit and unique" do
    long_case = String.duplicate("x", 300)
    a = BlockchainTestCatalog.test_name("BlockchainTests/A/same.json", long_case)
    b = BlockchainTestCatalog.test_name("BlockchainTests/B/same.json", long_case)

    assert String.length(a) == 200
    assert a != b
    assert "short from A/same.json" == BlockchainTestCatalog.test_name("x/A/same.json", "short")
  end

  defp with_rlp_size(test, size) do
    %{test | blocks: Enum.map(test.blocks, &%{&1 | rlp: :binary.copy(<<0>>, size)})}
  end
end
