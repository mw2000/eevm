# Writing a database adapter

eevm reads world state through the `EEVM.Database` behaviour and never writes
to it while executing. Every write lands in an overlay inside the
`%EEVM.Database{}` value. When a transaction or block finishes, the overlay
becomes an `EEVM.StateChanges`, and your adapter decides what to do with it.

An adapter has four required callbacks, all reads:

| Callback | Returns |
|----------|---------|
| `account(state, address)` | `{:ok, %{balance:, nonce:, code_hash:}}`, optionally with `code:`, or `{:ok, nil}` when the account doesn't exist |
| `code(state, code_hash)` | `{:ok, code}` |
| `storage(state, address, slot)` | `{:ok, word}`, 0 when the slot is unset |
| `block_hash(state, number)` | `{:ok, <<_::256>>}`, or `{:ok, nil}` when unknown; asked only for hashes the `EEVM.BlockEnv` doesn't carry |

Three more callbacks are required too, but a backend that can't do what
they ask returns `{:error, :unsupported}`. eevm never checks which functions
a module exports, so what an adapter supports is stated in its code:

- `commit(state, changes)` applies an `EEVM.StateChanges` and returns
  `{:ok, new_state}`. With it, `EEVM.transact/4` and `EEVM.Block.execute/4`
  commit for you and return the committed database. When it returns
  `{:error, :unsupported}`, they return the database with the writes still
  in its overlay, and you apply `result.changes` yourself. `EEVM.run/2` never
  commits.
- `accounts(state)` and `storage_slots(state, address)` enumerate the state
  as `{:ok, enumerable}`. Only `EEVM.StateRoot` needs them, so
  `EEVM.Block.execute/4`, which checks the header's state root, needs them
  too. They enumerate once: the database a block returns keeps the hashed
  state tries, and the next block rehashes only what it wrote. That assumes
  the state changes only through `commit/2`; after changing it any other
  way, wrap it again with `EEVM.Database.new/2`.

Addresses and storage words are integers; hashes are 32-byte binaries.

A callback that returns `{:error, reason}` stops execution, and the entry
point returns `{:error, {:database, reason}}`.

## An ETS-backed adapter

This adapter keeps state in an ETS table, so it persists across calls and can
be shared between processes. `commit/2` writes to the table and returns it
unchanged.

```elixir
defmodule MyApp.EtsDatabase do
  @behaviour EEVM.Database

  # Keys: {:account, address}, {:code, hash}, {:storage, address, slot},
  # and {:block_hash, number}.
  def new(table \\ :ets.new(:eevm_state, [:set, :public])),
    do: EEVM.Database.new(__MODULE__, table)

  @impl true
  def account(table, address), do: {:ok, get(table, {:account, address})}

  @impl true
  def code(table, code_hash), do: {:ok, get(table, {:code, code_hash}) || <<>>}

  @impl true
  def storage(table, address, slot), do: {:ok, get(table, {:storage, address, slot}) || 0}

  @impl true
  def block_hash(table, number), do: {:ok, get(table, {:block_hash, number})}

  @impl true
  def commit(table, %EEVM.StateChanges{accounts: changes}) do
    Enum.each(changes, fn
      {address, :destroyed} ->
        delete_account(table, address)

      {address, change} ->
        if change.destroyed?, do: delete_account(table, address)
        account = Map.take(change, [:balance, :nonce, :code_hash])
        :ets.insert(table, {{:account, address}, account})
        if change.code, do: :ets.insert(table, {{:code, change.code_hash}, change.code})

        Enum.each(change.storage, fn
          {slot, 0} -> :ets.delete(table, {:storage, address, slot})
          {slot, value} -> :ets.insert(table, {{:storage, address, slot}, value})
        end)
    end)

    {:ok, table}
  end

  @impl true
  def accounts(table), do: {:ok, :ets.select(table, [{{{:account, :"$1"}, :_}, [], [:"$1"]}])}

  @impl true
  def storage_slots(table, address),
    do: {:ok, :ets.select(table, [{{{:storage, address, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])}

  defp delete_account(table, address) do
    :ets.delete(table, {:account, address})
    :ets.match_delete(table, {{:storage, address, :_}, :_})
  end

  defp get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end
end
```

Seed it, run a transaction, and the table holds the result:

```elixir
db = MyApp.EtsDatabase.new()
:ets.insert(db.state, {{:account, sender}, %{balance: 10 ** 18, nonce: 0, code: <<>>}})

{:ok, result} = EEVM.transact(signed_tx, EEVM.BlockEnv.new(gas_limit: 30_000_000), db)
EEVM.Database.get_balance(result.db, recipient)
#=> 1000
```

An account may carry `code` in place of `code_hash`, as the seed above does.
eevm then hashes the code when it needs the hash.

## An RPC-backed adapter

An adapter can also read state from a node's JSON-RPC at a fixed block, which
lets you run transactions against mainnet state without a local copy. This
sketch takes the RPC client as a function, `rpc.(method, params)`, that
returns `{:ok, result}` or `{:error, reason}`. It can't commit or enumerate,
so `commit/2`, `accounts/1` and `storage_slots/2` return
`{:error, :unsupported}`, and `EEVM.transact/4` returns the writes in
`result.changes` and leaves the node alone.

```elixir
defmodule MyApp.RpcDatabase do
  @behaviour EEVM.Database

  # The state is {rpc, block_tag}, such as {&MyRpc.call/2, "0x1234567"}.
  def new(rpc, block_tag), do: EEVM.Database.new(__MODULE__, {rpc, block_tag})

  @impl true
  def account({rpc, tag}, address) do
    with {:ok, balance} <- call(rpc, "eth_getBalance", [EEVM.hex(<<address::160>>), tag]),
         {:ok, nonce} <- call(rpc, "eth_getTransactionCount", [EEVM.hex(<<address::160>>), tag]),
         {:ok, "0x" <> code} <- rpc.("eth_getCode", [EEVM.hex(<<address::160>>), tag]) do
      code = Base.decode16!(code, case: :mixed)

      # JSON-RPC can't tell a missing account from an empty one; treat both as missing.
      if balance == 0 and nonce == 0 and code == <<>>,
        do: {:ok, nil},
        else: {:ok, %{balance: balance, nonce: nonce, code: code}}
    end
  end

  # Accounts always carry their code, so eevm never asks for it by hash.
  @impl true
  def code(_state, _code_hash), do: {:error, :not_supported}

  @impl true
  def storage({rpc, tag}, address, slot),
    do: call(rpc, "eth_getStorageAt", [EEVM.hex(<<address::160>>), EEVM.hex(slot), tag])

  @impl true
  def block_hash({rpc, _tag}, number) do
    case rpc.("eth_getBlockByNumber", [EEVM.hex(number), false]) do
      {:ok, %{"hash" => "0x" <> hash}} -> {:ok, Base.decode16!(hash, case: :mixed)}
      {:ok, nil} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def commit(_state, _changes), do: {:error, :unsupported}

  @impl true
  def accounts(_state), do: {:error, :unsupported}

  @impl true
  def storage_slots(_state, _address), do: {:error, :unsupported}

  defp call(rpc, method, params) do
    with {:ok, "0x" <> hex} <- rpc.(method, params) do
      {:ok, if(hex == "", do: 0, else: String.to_integer(hex, 16))}
    end
  end
end
```

Each read is a network round trip, and eevm doesn't cache reads, so a real
adapter caches account, code, and storage reads in its state or in a process
it owns.

## Adapters written before 1.0

Before 1.0 the behaviour also had write and query callbacks (`get_balance/2`,
`set_balance/3`, `storage_store/4`, and so on). `EEVM.Database.new/2` still
accepts a module that implements only those, through the deprecated
`EEVM.Database.Legacy` shim, for one minor version. Move to the read
callbacks above before then.

Adapters written for the first read-only behaviour, where `commit/2`,
`accounts/1` and `storage_slots/2` were optional and the enumerations
returned a bare list, also keep working for one minor version: a missing
callback counts as `{:error, :unsupported}`. Add the three callbacks to
silence the compiler's missing-callback warning.
