defmodule Devx.Blocks do
  @moduledoc "Task 6: build, encode, validate, and execute a block."

  alias EEVM.Block
  alias EEVM.Block.Header
  alias EEVM.Transaction.{FeeMarket, Signer}

  @doc "A parent header to build on: block 100, 30M gas, 1 gwei base fee."
  def parent do
    Header.new(
      number: 100,
      timestamp: 1_000,
      gas_limit: 30_000_000,
      base_fee_per_gas: Devx.gwei(),
      hash: <<1::256>>
    )
  end

  @doc "Signed transactions from `Devx.sender/0`: deploy the token, then a legacy ETH transfer."
  def transactions(config) do
    {:ok, deploy} =
      %FeeMarket{
        nonce: 0,
        max_fee_per_gas: 3 * Devx.gwei(),
        max_priority_fee_per_gas: Devx.gwei(),
        gas_limit: 2_000_000,
        to: nil,
        data: Devx.token_initcode(500)
      }
      |> Signer.sign(Devx.private_key(), config)

    {:ok, transfer} = Devx.Transactions.legacy(1, 0xB0B, 5)
    [deploy, transfer]
  end

  @doc """
  The state the chain starts from: `Devx.funded_db/0` plus the system
  contracts `config`'s fork calls (from Prague, blocks are invalid without
  the EIP-7002 and EIP-7251 request contracts).
  """
  def genesis_db(config), do: EEVM.SystemContracts.install(Devx.funded_db(), config)

  @doc "Builds the child of `parent/0` holding `transactions/1` on `genesis_db/1`."
  def build(config) do
    Block.build(parent(), transactions(config), genesis_db(config),
      config: config,
      timestamp: 1_012,
      coinbase: 0xC0FFEE
    )
  end

  @doc "Round-trips `block` through RLP, then validates and executes it on `genesis_db/1`."
  def reexecute(block, config) do
    {:ok, decoded} = block |> Block.encode() |> Block.decode()

    with :ok <- Block.validate(decoded, parent(), config: config) do
      Block.execute(decoded, parent(), genesis_db(config), config: config)
    end
  end
end
