defmodule EEVM.TestSupport.BlockchainTestFixture do
  @moduledoc """
  Parses official `BlockchainTests` JSON fixtures into typed structs.

  The runner executes blocks from their canonical `rlp` through
  `EEVM.Block`, so the loader keeps only what that needs: the pre- and
  post-state, the network, the genesis block's RLP and hash, `lastblockhash`,
  and each block's `rlp`, optional `expectException`, and `blockHeader.hash`.
  The other JSON header and transaction fields are ignored; `InvalidBlocks`
  fixtures deliberately put malformed values there.
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
            hash: binary() | nil,
            expect_exception: String.t() | nil
          }

    defstruct [:block_number, :rlp, hash: nil, expect_exception: nil]
  end

  defmodule Case do
    @moduledoc false

    @type t :: %__MODULE__{
            name: String.t(),
            network: EEVM.HardforkConfig.spec_id(),
            transition: EEVM.TestSupport.BlockchainTestFixture.transition() | nil,
            pre: %{non_neg_integer() => Account.t()},
            post: %{non_neg_integer() => Account.t()},
            genesis_rlp: binary(),
            genesis_hash: binary(),
            last_block_hash: binary() | nil,
            blocks: [Block.t()]
          }

    defstruct [
      :name,
      :network,
      :transition,
      :pre,
      :post,
      :genesis_rlp,
      :genesis_hash,
      :last_block_hash,
      blocks: []
    ]
  end

  @typedoc """
  A mid-chain fork switch from a synthetic network name such as
  `PragueToOsakaAtTime15k`: blocks before `at` run on `from`, the rest on the
  case's `network`. `{:total_difficulty, ttd}` (from `...AtDiffC0000` names,
  in hex) activates on the first block whose parent's total difficulty
  reaches `ttd`, as the Merge did.
  """
  @type transition :: %{
          from: EEVM.HardforkConfig.spec_id(),
          at:
            {:block, non_neg_integer()}
            | {:timestamp, non_neg_integer()}
            | {:total_difficulty, non_neg_integer()}
        }

  @transition_network ~r/^(?<from>\w+?)To(?<to>\w+?)At(?<kind>Time|Diff)?(?<value>\w+)$/

  @spec load_file!(binary()) :: [Case.t()]
  def load_file!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn {name, payload} ->
      {network, transition} = parse_network!(Map.fetch!(payload, "network"))

      %Case{
        name: name,
        network: network,
        transition: transition,
        pre: parse_accounts(Map.fetch!(payload, "pre")),
        post: parse_accounts(Map.get(payload, "postState", %{})),
        genesis_rlp: parse_bytes!(Map.fetch!(payload, "genesisRLP")),
        genesis_hash: parse_bytes!(get_in(payload, ["genesisBlockHeader", "hash"])),
        last_block_hash: payload |> Map.get("lastblockhash") |> parse_hash(),
        blocks: Enum.map(Map.fetch!(payload, "blocks"), &parse_block/1)
      }
    end)
  end

  defp parse_block(block) do
    %Block{
      block_number: parse_quantity!(Map.get(block, "blocknumber", "0")),
      rlp: parse_bytes!(Map.fetch!(block, "rlp")),
      hash: block |> get_in(["blockHeader", "hash"]) |> parse_hash(),
      expect_exception: Map.get(block, "expectException")
    }
  end

  # `blockHeader` is absent from some blocks that are expected to fail.
  defp parse_hash(nil), do: nil
  defp parse_hash(hex), do: parse_bytes!(hex)

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

  defp parse_network!(name) do
    case Regex.named_captures(@transition_network, name) do
      nil ->
        {parse_fork!(name), nil}

      %{"from" => from, "to" => to, "kind" => kind, "value" => value} ->
        {parse_fork!(to), %{from: parse_fork!(from), at: parse_activation!(kind, value)}}
    end
  end

  defp parse_activation!("", value), do: {:block, String.to_integer(value)}
  defp parse_activation!("Time", value), do: {:timestamp, parse_thousands!(value)}
  defp parse_activation!("Diff", ttd), do: {:total_difficulty, String.to_integer(ttd, 16)}

  defp parse_thousands!(value) do
    case Integer.parse(value) do
      {n, "k"} -> n * 1_000
      {n, ""} -> n
    end
  end

  defp parse_fork!("Frontier"), do: :frontier
  defp parse_fork!("Homestead"), do: :homestead
  defp parse_fork!("Dao"), do: :homestead
  defp parse_fork!("EIP150"), do: :tangerine_whistle
  defp parse_fork!("EIP158"), do: :spurious_dragon
  defp parse_fork!("Byzantium"), do: :byzantium
  defp parse_fork!("Constantinople"), do: :constantinople
  defp parse_fork!("ConstantinopleFix"), do: :constantinople
  defp parse_fork!("Istanbul"), do: :istanbul
  defp parse_fork!("Berlin"), do: :berlin
  defp parse_fork!("London"), do: :london
  # Arrow Glacier only delays the difficulty bomb; execution matches London.
  defp parse_fork!("ArrowGlacier"), do: :london
  defp parse_fork!("Paris"), do: :paris
  defp parse_fork!("Merge"), do: :paris
  defp parse_fork!("Shanghai"), do: :shanghai
  defp parse_fork!("Cancun"), do: :cancun
  defp parse_fork!("Prague"), do: :prague
  defp parse_fork!("Osaka"), do: :osaka
  defp parse_fork!(other), do: raise(ArgumentError, "unsupported network #{inspect(other)}")

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
