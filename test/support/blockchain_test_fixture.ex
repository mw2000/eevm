defmodule EEVM.TestSupport.BlockchainTestFixture do
  @moduledoc """
  Parses official `BlockchainTests` JSON fixtures into typed structs.

  The runner executes blocks from their canonical `rlp` through
  `EEVM.Block`, so the loader keeps only what that needs: the pre- and
  post-state, the network, the genesis block's RLP, and each block's `rlp`
  and optional `expectException`. The JSON copies of headers and
  transactions are ignored; `InvalidBlocks` fixtures deliberately put
  malformed values there.
  """

  defmodule Account do
    @moduledoc false

    @type t :: %__MODULE__{
            balance: non_neg_integer(),
            nonce: non_neg_integer(),
            code: binary(),
            storage: %{non_neg_integer() => non_neg_integer()}
          }

    defstruct balance: 0, nonce: 0, code: <<>>, storage: %{}
  end

  defmodule Block do
    @moduledoc false

    @type t :: %__MODULE__{
            block_number: non_neg_integer(),
            rlp: binary(),
            expect_exception: String.t() | nil
          }

    defstruct [:block_number, :rlp, expect_exception: nil]
  end

  defmodule Case do
    @moduledoc false

    @type t :: %__MODULE__{
            name: String.t(),
            network: EEVM.HardforkConfig.spec_id(),
            pre: %{non_neg_integer() => Account.t()},
            post: %{non_neg_integer() => Account.t()},
            genesis_rlp: binary(),
            blocks: [Block.t()]
          }

    defstruct [:name, :network, :pre, :post, :genesis_rlp, blocks: []]
  end

  @spec load_file!(binary()) :: [Case.t()]
  def load_file!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn {name, payload} ->
      %Case{
        name: name,
        network: parse_network!(Map.fetch!(payload, "network")),
        pre: parse_accounts(Map.fetch!(payload, "pre")),
        post: parse_accounts(Map.get(payload, "postState", %{})),
        genesis_rlp: parse_bytes!(Map.fetch!(payload, "genesisRLP")),
        blocks: Enum.map(Map.fetch!(payload, "blocks"), &parse_block/1)
      }
    end)
  end

  defp parse_block(block) do
    %Block{
      block_number: parse_quantity!(Map.get(block, "blocknumber", "0")),
      rlp: parse_bytes!(Map.fetch!(block, "rlp")),
      expect_exception: Map.get(block, "expectException")
    }
  end

  defp parse_accounts(map) do
    Enum.into(map, %{}, fn {address, payload} ->
      {parse_address!(address),
       %Account{
         balance: parse_quantity!(Map.get(payload, "balance", "0x0")),
         nonce: parse_quantity!(Map.get(payload, "nonce", "0x0")),
         code: parse_bytes!(Map.get(payload, "code", "0x")),
         storage: parse_storage(Map.get(payload, "storage", %{}))
       }}
    end)
  end

  defp parse_storage(storage) do
    Enum.into(storage, %{}, fn {slot, value} ->
      {parse_quantity!(slot), parse_quantity!(value)}
    end)
  end

  defp parse_network!("Frontier"), do: :frontier
  defp parse_network!("Homestead"), do: :homestead
  defp parse_network!("Dao"), do: :homestead
  defp parse_network!("EIP150"), do: :tangerine_whistle
  defp parse_network!("EIP158"), do: :spurious_dragon
  defp parse_network!("Byzantium"), do: :byzantium
  defp parse_network!("Constantinople"), do: :constantinople
  defp parse_network!("ConstantinopleFix"), do: :constantinople
  defp parse_network!("Istanbul"), do: :istanbul
  defp parse_network!("Berlin"), do: :berlin
  defp parse_network!("London"), do: :london
  defp parse_network!("Paris"), do: :paris
  defp parse_network!("Merge"), do: :paris
  defp parse_network!("Shanghai"), do: :shanghai
  defp parse_network!("Cancun"), do: :cancun
  defp parse_network!("Prague"), do: :prague
  defp parse_network!("Osaka"), do: :osaka

  defp parse_network!(other) when is_binary(other) do
    # Synthetic transition names look like "<From>To<To>At<...>". The runner
    # cannot model mid-chain fork switching, so we surface the destination
    # fork and let problem cases land in skip.txt.
    head =
      other
      |> String.split("At", parts: 2)
      |> hd()

    case String.split(head, "To") do
      [_, to_fork] when to_fork != "" -> parse_network!(to_fork)
      _ -> raise ArgumentError, "unsupported network #{inspect(other)}"
    end
  end

  defp parse_address!(value) do
    value
    |> parse_bytes!()
    |> :binary.decode_unsigned()
  end

  defp parse_quantity!("0x"), do: 0
  defp parse_quantity!(""), do: 0

  defp parse_quantity!("0x" <> hex) do
    if hex == "" do
      0
    else
      String.to_integer(hex, 16)
    end
  end

  defp parse_quantity!(value) when is_binary(value), do: String.to_integer(value)
  defp parse_quantity!(value) when is_integer(value), do: value

  defp parse_bytes!("0x" <> hex), do: Base.decode16!(String.upcase(hex), case: :mixed)
  defp parse_bytes!(value) when is_binary(value), do: value
end
