defmodule Devx do
  @moduledoc """
  Shared setup for the examples: a funded account, the chain config, a block
  environment, and the ERC-20 in `priv/Token.sol`, compiled with solc 0.8.28.

  Each `Devx.*` module is one task a developer embedding eevm does, written
  only against eevm's public API. `test/` asserts what each returns.
  """

  alias EEVM.Transaction.Signer

  @external_resource token_path = Path.expand("../priv/Token.bin", __DIR__)
  @token_initcode token_path |> File.read!() |> String.trim() |> EEVM.bytes()

  @gwei 1_000_000_000

  @doc "1 gwei in wei."
  def gwei, do: @gwei

  @doc "The private key of the funded account (the EIP-155 example key)."
  def private_key, do: :binary.copy(<<0x46>>, 32)

  @doc "The funded account's address."
  def sender do
    {:ok, address} = Signer.address(private_key())
    address
  end

  @doc "Mainnet rules at Cancun."
  def config, do: EEVM.Config.new(:cancun, chain_id: 1)

  @doc "A block environment with a 1 gwei base fee and a coinbase to collect tips."
  def block_env do
    EEVM.BlockEnv.new(
      number: 1,
      timestamp: 12,
      gas_limit: 30_000_000,
      base_fee: @gwei,
      coinbase: 0xC0FFEE
    )
  end

  @doc "An in-memory state where `sender/0` holds 1 ether."
  def funded_db, do: EEVM.Database.InMemory.new(accounts: %{sender() => %{balance: 10 ** 18}})

  @doc "The token's initcode with its constructor argument, the initial supply, appended."
  def token_initcode(supply), do: @token_initcode <> <<supply::256>>
end
