# Interpreter workloads: run with `mix bench interpreter` (or `mix bench` for every suite).
#
# Each job runs one complete program through the public API. Before benchmarking, the
# script runs every job once and checks that it succeeds; the gas it used feeds the
# gas/s table that `EEVM.Bench.run/1` prints.

Code.require_file("support/asm.exs", __DIR__)
Code.require_file("support/bench.exs", __DIR__)

alias EEVM.Bench.Asm

# Fixed seed: random inputs are the same on every run.
:rand.seed(:exsss, {1, 2, 3})
alias EEVM.BlockEnv
alias EEVM.Context.Contract
alias EEVM.Database.InMemory
alias EEVM.Handler
alias EEVM.Transaction.{Legacy, Signer}

gas = 1_000_000_000
contract = 0xC0DE
callee = 0xCA11

execute = fn code, opts ->
  EEVM.execute(code, [gas: gas, contract: Contract.new(address: contract)] ++ opts)
end

# --- Compute -----------------------------------------------------------------------

# acc = ((acc + i) * 3) & mask, for i = n..1. Stack: [i, acc].
arith_loop =
  Asm.assemble([
    0,
    50_000,
    {:label, :loop},
    :dup1,
    :dup3,
    :add,
    3,
    :mul,
    0xFFFF_FFFF_FFFF,
    :and,
    :swap2,
    :pop,
    1,
    :swap1,
    :sub,
    :dup1,
    {:ref, :loop},
    :jumpi,
    :stop
  ])

# The smallest loop body: decrement and branch.
jump_loop =
  Asm.assemble([100_000, {:label, :loop}, 1, :swap1, :sub, :dup1, {:ref, :loop}, :jumpi, :stop])

# --- Memory ------------------------------------------------------------------------

# MSTORE(i * 32, i) then MLOAD(i * 32) for i = 1024..1, growing memory to 32 KiB.
mstore_mload =
  Asm.assemble([
    1024,
    {:label, :loop},
    :dup1,
    :dup1,
    5,
    :shl,
    :mstore,
    :dup1,
    5,
    :shl,
    :mload,
    :pop,
    1,
    :swap1,
    :sub,
    :dup1,
    {:ref, :loop},
    :jumpi,
    :stop
  ])

# CALLDATACOPY 32 KiB of calldata into memory, MCOPY it to the next 32 KiB, RETURN 64 KiB.
copy_size = 32 * 1024
copy_calldata = :rand.bytes(copy_size)

copy_and_return =
  Asm.assemble([
    copy_size,
    0,
    0,
    :calldatacopy,
    copy_size,
    0,
    copy_size,
    :mcopy,
    2 * copy_size,
    0,
    :return
  ])

# --- Keccak ------------------------------------------------------------------------

# KECCAK256 of a fresh 32-byte word, 5,000 times.
keccak_words =
  Asm.assemble([
    5_000,
    {:label, :loop},
    :dup1,
    0,
    :mstore,
    32,
    0,
    :keccak256,
    :pop,
    1,
    :swap1,
    :sub,
    :dup1,
    {:ref, :loop},
    :jumpi,
    :stop
  ])

# KECCAK256 over 64 KiB of memory (expands memory, then hashes it in one read).
keccak_64k = Asm.assemble([64 * 1024, 0, :keccak256, :stop])

# --- Storage -----------------------------------------------------------------------

# SSTORE(i, i) then SLOAD(i) for i = 500..1: cold writes, warm reads.
sstore_sload =
  Asm.assemble([
    500,
    {:label, :loop},
    :dup1,
    :dup1,
    :sstore,
    :dup1,
    :sload,
    :pop,
    1,
    :swap1,
    :sub,
    :dup1,
    {:ref, :loop},
    :jumpi,
    :stop
  ])

# --- Calls (stStaticCall/static_Call50000-style) -----------------------------------

# STATICCALL a contract that SLOADs and MSTOREs, 2,000 times.
call_loop =
  Asm.assemble([
    2_000,
    {:label, :loop},
    0,
    0,
    0,
    0,
    callee,
    0xFFFF,
    :staticcall,
    :pop,
    1,
    :swap1,
    :sub,
    :dup1,
    {:ref, :loop},
    :jumpi,
    :stop
  ])

callee_code = Asm.assemble([0, :sload, 0, :mstore, :stop])
call_world = EEVM.Database.InMemory.new(accounts: %{callee => %{balance: 0, code: callee_code}})

# --- ERC-20 transfer through EEVM.Handler ---------------------------------------------

# transfer(address to, uint256 amount): balances live at keccak256(owner . 0).
transfer_event = 0xDDF252AD1BE2C89B69C2B068FC378DAA952BA7F163C4A11628F55A4DF523B3EF

erc20 =
  Asm.assemble([
    0,
    :calldataload,
    0xE0,
    :shr,
    0xA9059CBB,
    :eq,
    {:ref, :transfer},
    :jumpi,
    0,
    0,
    :revert,
    {:label, :transfer},
    # sender slot and balance: [amount, balance, sender_slot]
    :caller,
    0,
    :mstore,
    64,
    0,
    :keccak256,
    :dup1,
    :sload,
    0x24,
    :calldataload,
    :dup1,
    :dup3,
    :lt,
    {:ref, :fail},
    :jumpi,
    # balances[sender] = balance - amount: leaves [amount]
    :dup1,
    :swap2,
    :sub,
    :swap1,
    :swap2,
    :sstore,
    # balances[to] += amount: leaves [amount]
    4,
    :calldataload,
    0,
    :mstore,
    64,
    0,
    :keccak256,
    :dup1,
    :sload,
    :dup3,
    :add,
    :swap1,
    :sstore,
    # emit Transfer(caller, to, amount)
    0,
    :mstore,
    4,
    :calldataload,
    :caller,
    transfer_event,
    32,
    0,
    :log3,
    1,
    0,
    :mstore,
    32,
    0,
    :return,
    {:label, :fail},
    0,
    0,
    :revert
  ])

private_key = :crypto.hash(:sha256, "eevm benchmark sender")
{:ok, <<4, public_key::binary-64>>} = ExSecp256k1.create_public_key(private_key)
<<_::binary-12, sender::160>> = ExKeccak.hash_256(public_key)
token = 0x70CE
recipient = 0xB0B
balance_slot = fn owner -> :binary.decode_unsigned(ExKeccak.hash_256(<<owner::256, 0::256>>)) end

erc20_db =
  InMemory.new(
    accounts: %{
      sender => %{balance: 10 ** 18, nonce: 0, code: <<>>},
      token => %{balance: 0, nonce: 1, code: erc20}
    },
    storage: %{token => %{balance_slot.(sender) => 1_000_000}}
  )

unsigned_transfer = %Legacy{
  nonce: 0,
  gas_price: 1,
  gas_limit: 100_000,
  to: <<token::160>>,
  value: 0,
  data: <<0xA9059CBB::32, recipient::256, 1_000::256>>,
  v: 0,
  r: 0,
  s: 0
}

{:ok, {<<r::256, s::256>>, recovery_id}} =
  unsigned_transfer |> Signer.signing_hash(1) |> ExSecp256k1.sign_compact(private_key)

transfer_tx = %{unsigned_transfer | v: 37 + recovery_id, r: r, s: s}
block = BlockEnv.new(gas_limit: 30_000_000, base_fee: 0, coinbase: 0xC0F0)

# --- Jobs ------------------------------------------------------------------------------

jobs = %{
  "compute: arithmetic loop (50k)" => fn -> execute.(arith_loop, []) end,
  "compute: jump loop (100k)" => fn -> execute.(jump_loop, []) end,
  "memory: MSTORE/MLOAD 32 KiB" => fn -> execute.(mstore_mload, []) end,
  "memory: CALLDATACOPY+MCOPY+RETURN 32 KiB" => fn ->
    execute.(copy_and_return, contract: Contract.new(address: contract, calldata: copy_calldata))
  end,
  "keccak: 5k x 32 B" => fn -> execute.(keccak_words, []) end,
  "keccak: 64 KiB" => fn -> execute.(keccak_64k, []) end,
  "storage: SSTORE/SLOAD 500 slots" => fn -> execute.(sstore_sload, []) end,
  "calls: STATICCALL loop (2k)" => fn -> execute.(call_loop, db: call_world) end,
  "erc20: transfer via Handler" => fn -> Handler.execute(transfer_tx, block, erc20_db) end
}

gas_used = fn
  {:ok, %EEVM.TransactionResult{status: :success, gas_used: used, logs: [_]}} -> used
  %{status: :stopped, frame: frame} -> gas - frame.gas
end

jobs
|> Map.new(fn {name, job} -> {name, {gas_used.(job.()), job}} end)
|> EEVM.Bench.run()
