defmodule EEVM.SystemContractsTest do
  use ExUnit.Case, async: true

  alias EEVM.{Block, Config, Database, SystemContracts}
  alias EEVM.Block.Header
  alias EEVM.Database.InMemory
  alias EEVM.Transaction.{FeeMarket, Signer}

  doctest EEVM.SystemContracts

  @private_key <<0x46::256>>
  @withdrawal_request_contract 0x00000961EF480EB55E80D19AD83579A64C007002
  @consolidation_request_contract 0x0000BBDDC7CE488642FB579F8B00F3A590007251

  describe "genesis_accounts/1" do
    test "adds the request contracts at Prague, not Cancun" do
      cancun = SystemContracts.genesis_accounts(:cancun)
      prague = SystemContracts.genesis_accounts(:prague)

      refute Map.has_key?(cancun, @withdrawal_request_contract)
      refute Map.has_key?(cancun, @consolidation_request_contract)

      assert %{nonce: 1, balance: 0, code: <<0x33, _::binary>>} =
               prague[@withdrawal_request_contract]

      assert %{nonce: 1, balance: 0, code: <<0x33, _::binary>>} =
               prague[@consolidation_request_contract]

      assert Map.keys(SystemContracts.genesis_accounts(:osaka)) == Map.keys(prague)
    end
  end

  describe "install/2" do
    test "keeps the storage of an account it replaces" do
      db =
        InMemory.new()
        |> Database.storage_store(@withdrawal_request_contract, 7, 9)
        |> SystemContracts.install(Config.new(:prague))

      assert Database.storage_load(db, @withdrawal_request_contract, 7) == 9
      assert Database.get_nonce(db, @withdrawal_request_contract) == 1
    end
  end

  describe "Prague blocks" do
    test "are rejected on a state without the request contracts" do
      tx = sign(%FeeMarket{nonce: 0, to: 0xB0B, value: 1})
      {:ok, sender} = Signer.address(@private_key)
      db = InMemory.new(accounts: %{sender => %{balance: 10 ** 18}})

      assert Block.build(parent(), [tx], db, hardfork: :prague, timestamp: 12) ==
               {:error, :system_contract_empty}
    end

    # The installed bytecode must behave as EIP-7002 and EIP-7251 specify: a
    # request transaction pays the minimum fee of 1 wei (excess 0), and the
    # end-of-block system calls return `source ++ pubkey ++ amount` with the
    # amount little-endian (EIP-7002) and `source ++ source_pubkey ++
    # target_pubkey` (EIP-7251), as EIP-7685 requests of types 0x01 and 0x02.
    test "collect withdrawal and consolidation requests from the installed contracts" do
      pubkey = :binary.copy(<<0xAA>>, 48)
      target = :binary.copy(<<0xBB>>, 48)
      amount = 0x0102030405060708

      withdrawal =
        sign(%FeeMarket{
          nonce: 0,
          to: @withdrawal_request_contract,
          value: 1,
          data: pubkey <> <<amount::64>>
        })

      consolidation =
        sign(%FeeMarket{
          nonce: 1,
          to: @consolidation_request_contract,
          value: 1,
          data: pubkey <> target
        })

      {:ok, sender} = Signer.address(@private_key)
      accounts = Map.put(SystemContracts.genesis_accounts(:prague), sender, %{balance: 10 ** 18})
      db = InMemory.new(accounts: accounts)

      assert {:ok, block, result} =
               Block.build(parent(), [withdrawal, consolidation], db,
                 hardfork: :prague,
                 timestamp: 12
               )

      assert result.requests == [
               <<0x01, sender::160, pubkey::binary, amount::little-64>>,
               <<0x02, sender::160, pubkey::binary, target::binary>>
             ]

      assert {:ok, _} = Block.execute(block, parent(), db, hardfork: :prague)
    end
  end

  defp parent, do: Header.new(gas_limit: 30_000_000, base_fee_per_gas: 7, hash: <<1::256>>)

  defp sign(tx) do
    tx = %{tx | max_priority_fee_per_gas: 1, max_fee_per_gas: 10, gas_limit: 500_000}
    {:ok, tx} = Signer.sign(tx, @private_key, Config.new(:prague))
    tx
  end
end
