defmodule EEVM.SystemContracts do
  @moduledoc """
  Genesis setup for the system contracts that blocks call from Cancun on.

  | EIP | From | Address | Called |
  |-----|------|---------|--------|
  | EIP-4788 beacon roots | Cancun | `0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02` | block start |
  | EIP-2935 block hashes | Prague | `0x0000F90827F1C53a10cb7A02335B175320002935` | block start |
  | EIP-7002 withdrawal requests | Prague | `0x00000961Ef480Eb55e80D19ad83579A64c007002` | block end |
  | EIP-7251 consolidation requests | Prague | `0x0000BBdDc7CE488642fb579F8B00f3a590007251` | block end |

  On mainnet each contract was deployed by an ordinary transaction before its
  fork activated. A chain started from scratch, such as a devnet or a test,
  has no such history, so `genesis_accounts/1` returns the contracts a fork
  calls as genesis accounts, and `install/2` writes them into a database.

  Block execution never installs them itself: a Prague block whose state
  lacks the EIP-7002 or EIP-7251 contract fails with `:system_contract_empty`,
  as those EIPs require. A missing EIP-4788 or EIP-2935 contract makes its
  block-start call a no-op. `EEVM.SystemContracts.BeaconRoots` and
  `EEVM.SystemContracts.BlockHashes` drive and read those two contracts.
  """

  alias EEVM.{Config, Database, HardforkConfig}
  alias EEVM.SystemContracts.{BeaconRoots, BlockHashes}

  @withdrawal_request_address 0x00000961EF480EB55E80D19AD83579A64C007002
  @consolidation_request_address 0x0000BBDDC7CE488642FB579F8B00F3A590007251

  # Deployed runtime bytecode from EIP-7002, section "Deployment" (the code
  # its deployment transaction returns).
  @withdrawal_request_code Base.decode16!(
                             "3373FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE1460CB5760115F54807F" <>
                               "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" <>
                               "146101F457600182026001905F5B5F8211156068578101908302848302900491" <>
                               "6001019190604D565B909390049250505036603814608857366101F457346101" <>
                               "F4575F5260205FF35B34106101F4576001546001016001556003548060030260" <>
                               "04013381556001015F35815560010160203590553360601B5F5260385F601437" <>
                               "604C5FA0600101600355005B6003546002548082038060101160DF575060105B" <>
                               "5F5B8181146101835782810160030260040181604C02815460601B8152601401" <>
                               "816001015481526020019060020154807FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" <>
                               "FF00000000000000000000000000000000168252906010019060401C90816038" <>
                               "1C81600701538160301C81600601538160281C81600501538160201C81600401" <>
                               "538160181C81600301538160101C81600201538160081C816001015353600101" <>
                               "60E1565B910180921461019557906002556101A0565B90505F6002555F600355" <>
                               "5B5F54807FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" <>
                               "FFFFFFFFFF14156101CD57505F5B6001546002828201116101E25750505F6101" <>
                               "E8565B01600290035B5F555F600155604C025FF35B5F5FFD"
                           )

  # Deployed runtime bytecode from EIP-7251, section "Deployment".
  @consolidation_request_code Base.decode16!(
                                "3373FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE1460D35760115F54807F" <>
                                  "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" <>
                                  "1461019A57600182026001905F5B5F8211156068578101908302848302900491" <>
                                  "6001019190604D565B9093900492505050366060146088573661019A57346101" <>
                                  "9A575F5260205FF35B341061019A576001546001016001556003548060040260" <>
                                  "04013381556001015F358155600101602035815560010160403590553360601B" <>
                                  "5F5260605F60143760745FA0600101600355005B600354600254808203806002" <>
                                  "1160E7575060025B5F5B81811461012957828101600402600401816074028154" <>
                                  "60601B8152601401816001015481526020018160020154815260200190600301" <>
                                  "54905260010160E9565B910180921461013B5790600255610146565B90505F60" <>
                                  "02555F6003555B5F54807FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" <>
                                  "FFFFFFFFFFFFFFFFFFFFFF141561017357505F5B600154600182820111610188" <>
                                  "5750505F61018E565B01600190035B5F555F6001556074025FF35B5F5FFD"
                              )

  @doc """
  Returns the system contracts that blocks of `fork` call, as genesis accounts
  in the shape `EEVM.Database.InMemory.new/1` takes:
  `%{address => %{balance: 0, nonce: 1, code: code}}`.

  `fork` is an `EEVM.Config` or a hardfork name. Each contract is included
  from the fork that activates its EIP, with its canonical deployed code and
  the nonce of 1 that its deployment left on mainnet, so state roots match
  other clients'. Forks before Cancun need none.

  ## Examples

      iex> EEVM.SystemContracts.genesis_accounts(:prague) |> Map.keys() |> Enum.sort()
      [
        0x00000961EF480EB55E80D19AD83579A64C007002,
        0x0000BBDDC7CE488642FB579F8B00F3A590007251,
        0x0000F90827F1C53A10CB7A02335B175320002935,
        0x000F3DF6D732807EF1319FB7B8BB8522D0BEAC02
      ]
      iex> EEVM.SystemContracts.genesis_accounts(EEVM.Config.new(:cancun))
      %{0x000F3DF6D732807EF1319FB7B8BB8522D0BEAC02 => %{balance: 0, nonce: 1,
        code: EEVM.SystemContracts.BeaconRoots.deployed_bytecode()}}
      iex> EEVM.SystemContracts.genesis_accounts(:shanghai)
      %{}
  """
  @spec genesis_accounts(Config.t() | HardforkConfig.spec_id()) :: %{
          non_neg_integer() => %{balance: 0, nonce: 1, code: binary()}
        }
  def genesis_accounts(fork) do
    hardfork = hardfork(fork)

    for {flag, address, code} <- contracts(),
        HardforkConfig.enabled?(hardfork, flag),
        into: %{} do
      {address, %{balance: 0, nonce: 1, code: code}}
    end
  end

  @doc """
  Writes the accounts `genesis_accounts/1` returns for `fork` into `db`,
  replacing any accounts at those addresses but keeping their storage.

  ## Example

      iex> db = EEVM.SystemContracts.install(EEVM.Database.InMemory.new(), :prague)
      iex> EEVM.Database.get_nonce(db, 0x00000961EF480EB55E80D19AD83579A64C007002)
      1
  """
  @spec install(Database.t(), Config.t() | HardforkConfig.spec_id()) :: Database.t()
  def install(%Database{} = db, fork) do
    Enum.reduce(genesis_accounts(fork), db, fn {address, account}, db ->
      Database.put_account(db, address, account)
    end)
  end

  defp hardfork(%Config{hardfork: hardfork}), do: hardfork
  defp hardfork(spec_id) when is_atom(spec_id), do: HardforkConfig.new(spec_id)

  defp contracts do
    [
      {:eip_4788, BeaconRoots.address(), BeaconRoots.deployed_bytecode()},
      {:eip_2935, BlockHashes.address(), BlockHashes.deployed_bytecode()},
      {:eip_7002, @withdrawal_request_address, @withdrawal_request_code},
      {:eip_7251, @consolidation_request_address, @consolidation_request_code}
    ]
  end
end
