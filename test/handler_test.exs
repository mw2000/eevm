defmodule EEVM.HandlerTest do
  use ExUnit.Case, async: true

  alias EEVM.Block.{Bloom, Receipt}
  alias EEVM.{BlockEnv, Config, Database, Delegation, Handler, Tracer, TransactionResult}
  alias EEVM.Crypto.Keccak
  alias EEVM.Database.InMemory
  alias EEVM.Transaction.{Authorization, Blob, Envelope, FeeMarket, Legacy, SetCode, Signer}

  doctest EEVM.Handler.PreExecution
  doctest EEVM.Handler.PostExecution

  @priv_key <<
    120,
    128,
    174,
    201,
    52,
    19,
    241,
    23,
    239,
    20,
    189,
    78,
    109,
    19,
    8,
    117,
    171,
    44,
    125,
    125,
    85,
    160,
    100,
    250,
    195,
    194,
    247,
    189,
    81,
    81,
    99,
    128
  >>

  @chain_id 1
  @coinbase 0xC0F0
  @recipient 0xB0B

  @authority_key :crypto.hash(:sha256, "eip-7702 authority")
  @delegate 0xDE1E
  @secp256k1n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  describe "execute/4 — legacy value transfer" do
    test "moves value, charges gas, bumps nonce" do
      sender = sender_address()
      starting_balance = 1_000_000

      tx = legacy_value_transfer(value: 1_000)
      db = db_with_sender(balance: starting_balance)

      assert {:ok, %TransactionResult{} = result} = run(tx, db)

      assert result.status == :success
      assert result.sender == sender
      assert result.gas_used == 21_000
      assert result.contract_address == nil
      assert result.return_data == <<>>

      # 1_000_000 - (21_000 * 1) - 1_000 = 978_000
      assert Database.get_balance(result.db, sender) == 978_000
      assert Database.get_balance(result.db, @recipient) == 1_000
      assert Database.get_nonce(result.db, sender) == 1
    end

    test "intrinsic gas too low when gas_limit < 21000" do
      tx = legacy_value_transfer(gas_limit: 20_999)

      assert {:error, :intrinsic_gas_too_low} = run(tx, db_with_sender())
    end

    test "insufficient balance for upfront cost" do
      tx = legacy_value_transfer(gas_limit: 21_000, gas_price: 1, value: 100_000_000)

      assert {:error, :insufficient_balance} = run(tx, db_with_sender(balance: 100))
    end

    test "rejects an unsigned transaction" do
      unsigned = %Legacy{
        nonce: 0,
        gas_price: 1,
        gas_limit: 21_000,
        to: @recipient,
        value: 0,
        data: <<>>,
        v: 27,
        r: 0,
        s: 0
      }

      assert {:error, _} = run(unsigned, db_with_sender())
    end
  end

  describe "execute/4 — deprecated binary addresses" do
    test "a 20-byte binary `to` runs the same as the integer address" do
      db = Database.put_code(db_with_sender(), @recipient, <<0x60, 1, 0x60, 0, 0x55, 0x00>>)
      tx = legacy_value_transfer(gas_limit: 50_000)
      binary_to = legacy_value_transfer(gas_limit: 50_000, to: <<@recipient::160>>)

      assert {:ok, expected} = run(tx, db)
      assert {:ok, result} = run(binary_to, db)
      assert Database.storage_load(result.db, @recipient, 0) == 1
      assert result.gas_used == expected.gas_used
    end
  end

  describe "execute/4 — before Spurious Dragon" do
    # execution-specs Frontier process_message touches the call target, and
    # process_transaction sets the coinbase balance, so both exist afterwards
    # even with no value and no fee (EEST frontier/touch/test_zero_gas_price_and_touching).
    test "a zero-value, zero-fee call creates the target and the coinbase until EIP-161" do
      tx = pre_eip155_legacy(to: @recipient, gas_limit: 21_000, gas_price: 0)

      assert {:ok, %TransactionResult{status: :success, db: frontier}} =
               run_fork(tx, db_with_sender(), :frontier)

      assert Database.get_account(frontier, @recipient) == %{balance: 0, nonce: 0, code: <<>>}
      assert Database.get_account(frontier, @coinbase) == %{balance: 0, nonce: 0, code: <<>>}

      assert {:ok, %TransactionResult{status: :success, db: spurious}} =
               run_fork(tx, db_with_sender(), :spurious_dragon)

      refute Database.account_exists?(spurious, @recipient)
      refute Database.account_exists?(spurious, @coinbase)
    end

    # Initcode PUSH1 100 PUSH1 0 RETURN returns 100 bytes, a 20,000-gas deposit
    # (EEST frontier/create/test_create_deposit_oog).
    @initcode <<0x60, 0x64, 0x60, 0x00, 0xF3>>

    test "a creation tx that can't pay the code deposit deploys empty code until EIP-2" do
      # Frontier intrinsic gas: 21,000 + 4 * 68 + 4 = 21,276, which leaves
      # 8,724 for the initcode and too little for the deposit.
      tx = pre_eip155_legacy(to: nil, data: @initcode, gas_limit: 30_000)

      assert {:ok, %TransactionResult{status: :success} = result} =
               run_fork(tx, db_with_sender(), :frontier)

      assert result.contract_address != nil
      assert Database.account_exists?(result.db, result.contract_address)
      assert Database.get_code(result.db, result.contract_address) == <<>>
      # Only the initcode is paid for: 6 gas of opcodes and 12 of memory
      # (4 words). The deposit isn't charged.
      assert result.gas_used == 21_276 + 18

      # Homestead adds 32,000 intrinsic gas, so the initcode again gets 8,724.
      tx = pre_eip155_legacy(to: nil, data: @initcode, gas_limit: 62_000)

      assert {:ok, %TransactionResult{status: {:halt, :out_of_gas}} = result} =
               run_fork(tx, db_with_sender(), :homestead)

      assert result.contract_address == nil
      assert result.gas_used == 62_000
    end
  end

  describe "execute/4 — chain id" do
    test "comes from the config and must match an EIP-155 signature" do
      {:ok, tx} =
        Signer.sign(
          %Legacy{gas_price: 1, gas_limit: 21_000, to: @recipient},
          @priv_key,
          Config.new(:cancun, chain_id: 5)
        )

      db = db_with_sender(balance: 1_000_000)

      assert {:ok, %TransactionResult{status: :success}} =
               Handler.execute(tx, simple_block(), db, config: Config.new(:cancun, chain_id: 5))

      assert {:error, :invalid_v} =
               Handler.execute(tx, simple_block(), db, config: Config.new(:cancun, chain_id: 1))

      # The deprecated :chain_id option still overrides the config's.
      assert {:ok, _} = Handler.execute(tx, simple_block(), db, config: Config.new(), chain_id: 5)
    end
  end

  describe "execute/4 — eip-1559 fee market" do
    test "uses min(max_fee, basefee + tip), credits coinbase the priority fee" do
      starting_balance = 10_000_000

      tx =
        sign_eip1559(%FeeMarket{
          chain_id: @chain_id,
          nonce: 0,
          max_priority_fee_per_gas: 2,
          max_fee_per_gas: 10,
          gas_limit: 21_000,
          to: @recipient,
          value: 0,
          data: <<>>,
          access_list: [],
          y_parity: 0,
          r: 0,
          s: 0
        })

      db = db_with_sender(balance: starting_balance)
      block = simple_block(base_fee: 5)

      assert {:ok, %TransactionResult{db: post_db, gas_used: 21_000}} =
               run(tx, db, block)

      # effective_price = min(10, 5 + 2) = 7
      # coinbase reward = (7 - 5) * 21_000 = 42_000
      assert Database.get_balance(post_db, @coinbase) == 42_000
      # sender pays gas_used * effective_price = 21_000 * 7 = 147_000
      assert Database.get_balance(post_db, sender_address()) == starting_balance - 147_000
    end

    test "debits gas_limit * effective price, not the fee cap, before execution" do
      starting_balance = 10_000_000

      tx =
        sign_eip1559(%FeeMarket{
          chain_id: @chain_id,
          nonce: 0,
          max_priority_fee_per_gas: 2,
          max_fee_per_gas: 10,
          gas_limit: 100_000,
          to: <<@recipient::unsigned-big-160>>,
          value: 0,
          data: <<>>,
          access_list: [],
          y_parity: 0,
          r: 0,
          s: 0
        })

      # Recipient stores the sender's balance in slot 0: ORIGIN BALANCE PUSH1 0 SSTORE STOP.
      code = <<0x32, 0x31, 0x60, 0x00, 0x55, 0x00>>
      db = Database.put_code(db_with_sender(balance: starting_balance), @recipient, code)

      assert {:ok, %TransactionResult{status: :success, post_state_db: post_db}} =
               run(tx, db, simple_block(base_fee: 5))

      # execution-specs process_transaction debits tx.gas * effective_gas_price:
      # 100_000 * min(10, 5 + 2) = 700_000, not 100_000 * 10 (bcEIP1559/burnVerify).
      assert Database.storage_load(post_db, @recipient, 0) == starting_balance - 700_000
    end
  end

  describe "execute/4 — GASPRICE" do
    test "is the effective price per gas for an EIP-1559 transaction" do
      tx =
        sign_eip1559(%FeeMarket{
          chain_id: @chain_id,
          nonce: 0,
          max_priority_fee_per_gas: 2,
          max_fee_per_gas: 10,
          gas_limit: 100_000,
          to: @recipient,
          value: 0,
          data: <<>>,
          access_list: [],
          y_parity: 0,
          r: 0,
          s: 0
        })

      # Recipient stores GASPRICE in slot 0: GASPRICE PUSH1 0 SSTORE STOP.
      db = Database.put_code(db_with_sender(), @recipient, <<0x3A, 0x60, 0x00, 0x55, 0x00>>)

      assert {:ok, %TransactionResult{status: :success, db: post_db}} =
               run(tx, db, simple_block(base_fee: 5))

      # EIP-1559: min(max_fee 10, base_fee 5 + tip 2) = 7.
      assert Database.storage_load(post_db, @recipient, 0) == 7
    end
  end

  describe "execute/4 — eip-4844 blob fee" do
    # EIP-4844: the sender burns get_total_blob_gas(tx) * blob_base_fee up front,
    # where get_total_blob_gas = GAS_PER_BLOB (131_072) * blob count. Validity
    # requires balance >= gas_limit * max_fee_per_gas
    # + total_blob_gas * max_fee_per_blob_gas + value.
    @blob_gas 2 * 131_072
    # 21_000 * 10 + 262_144 * 4
    @max_upfront 1_258_576

    test "burns blob gas at the block's blob base fee; coinbase gets only the tip" do
      block = simple_block(base_fee: 5, blob_base_fee: 3)

      assert {:ok, %TransactionResult{db: post_db, gas_used: 21_000}} =
               run(blob_tx(), db_with_sender(balance: @max_upfront), block)

      # gas: 21_000 * min(10, 5 + 2) = 147_000; blob: 262_144 * 3 = 786_432
      assert Database.get_balance(post_db, sender_address()) ==
               @max_upfront - 147_000 - @blob_gas * 3

      assert Database.get_balance(post_db, @coinbase) == 21_000 * 2
    end

    test "requires the balance to cover blob gas at max_fee_per_blob_gas" do
      block = simple_block(base_fee: 5, blob_base_fee: 3)

      assert {:error, :insufficient_balance} =
               run(blob_tx(), db_with_sender(balance: @max_upfront - 1), block)
    end
  end

  describe "execute/4 — CREATE" do
    test "deploys runtime code at CREATE-derived address" do
      # Initcode that returns a single STOP byte as runtime code:
      #   PUSH1 0   ; mstore8 value
      #   PUSH1 0   ; mstore8 offset
      #   MSTORE8
      #   PUSH1 1   ; return size
      #   PUSH1 0   ; return offset
      #   RETURN
      initcode = <<0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xF3>>

      tx =
        sign_legacy(
          %Legacy{
            nonce: 0,
            gas_price: 1,
            gas_limit: 200_000,
            to: nil,
            value: 0,
            data: initcode,
            v: 0,
            r: 0,
            s: 0
          },
          @chain_id
        )

      db = db_with_sender(balance: 10_000_000)

      assert {:ok, result} = run(tx, db)
      assert result.status == :success
      assert is_integer(result.contract_address)
      assert Database.get_code(result.db, result.contract_address) == <<0x00>>
      assert Database.get_nonce(result.db, result.contract_address) == 1
    end

    test "initcode runs with the new contract's nonce at 1" do
      # Initcode issues the same empty-initcode CREATE2 twice; the second collides.
      # EIP-161: the new contract starts at nonce 1. EIP-684/EIP-1014: every
      # CREATE2, colliding or not, bumps the creator's nonce, so 1 + 2 = 3
      # (ethereum/tests stCreate2/create2collisionSelfdestructed).
      create2_empty = <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0xF5, 0x50>>

      tx = create_tx(create2_empty <> create2_empty <> <<0x00>>, 0)

      assert {:ok, result} = run(tx, db_with_sender(balance: 10_000_000))
      assert result.status == :success
      assert Database.get_nonce(result.db, result.contract_address) == 3
    end

    test "initcode that SELFDESTRUCTs leaves no account behind (EIP-6780)" do
      # PUSH1 0xBB SELFDESTRUCT. EIP-6780: a contract created in the same
      # transaction is deleted (ethereum/tests
      # stCreate2/CREATE2_ContractSuicideDuringInit_ThenStoreThenReturn).
      tx = create_tx(<<0x60, 0xBB, 0xFF>>, 5)

      assert {:ok, result} = run(tx, db_with_sender(balance: 10_000_000))
      assert result.status == :success
      refute Database.account_exists?(result.db, result.contract_address)
      assert Database.get_balance(result.db, 0xBB) == 5
    end

    test "creating over an account with code fails and consumes all gas (EIP-684)" do
      # keccak256(rlp([sender, 0]))[12:]: 0xd6 = list of 22 bytes, 0x94 = 20-byte string.
      <<_::binary-size(12), target::unsigned-big-160>> =
        Keccak.hash_256(<<0xD6, 0x94, sender_address()::unsigned-big-160, 0x80>>)

      db = Database.put_code(db_with_sender(balance: 10_000_000), target, <<0xFE>>)
      # Initcode that would deploy a STOP byte if it ran.
      tx = create_tx(<<0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xF3>>, 0)

      assert {:ok, result} = run(tx, db)
      assert result.status == {:halt, :create_collision}
      assert result.gas_used == 200_000
      assert result.contract_address == nil
      assert Database.get_code(result.db, target) == <<0xFE>>
      assert Database.get_nonce(result.db, sender_address()) == 1
    end

    test "initcode that STOPs after a sub-call deploys empty code" do
      # CALL the identity precompile with 32 bytes, then STOP. The call's 32
      # bytes of output are not the initcode's output: nothing is deployed and
      # no code deposit is charged. Intrinsic 21_000 + 32_000 + 180 calldata +
      # 2 initcode; execution 6 PUSH1 + GAS + CALL + identity (15 + 3) + memory 3.
      initcode =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x20, 0x60, 0x00, 0x60, 0x00, 0x60, 0x04, 0x5A, 0xF1,
          0x00>>

      assert {:ok, result} = run(create_tx(initcode, 0), db_with_sender())
      assert result.status == :success
      assert Database.get_code(result.db, result.contract_address) == <<>>
      assert result.gas_used == 53_182 + 18 + 2 + 100 + 18 + 3
    end
  end

  describe "execute/4 — precompile as the transaction target" do
    # SHA256 (0x02) costs 60 + 12 per word; "abc" is one word → 72 gas.
    # Intrinsic gas: 21_000 + 3 non-zero calldata bytes × 16 = 21_048.
    test "runs the precompile, charges its gas, and returns its output" do
      tx = legacy_value_transfer(to: 0x02, data: "abc", gas_limit: 30_000)

      assert {:ok, result} = run(tx, db_with_sender())
      assert result.status == :success
      assert result.gas_used == 21_048 + 72
      assert result.return_data == :crypto.hash(:sha256, "abc")
    end

    test "a precompile that runs out of gas consumes the whole gas limit" do
      tx = legacy_value_transfer(to: 0x02, data: "abc", gas_limit: 21_100)

      assert {:ok, result} = run(tx, db_with_sender())
      assert result.status != :success
      assert result.gas_used == 21_100
      assert result.return_data == <<>>
    end
  end

  describe "execute/4 — gas refunds" do
    test "a refund earned in a successful child frame reaches the transaction" do
      # The recipient CALLs a child that writes its slot 0 (holding 2). Clearing
      # it and resetting it to 3 cost the same; only clearing earns 4_800.
      parent_code = :binary.copy(<<0x60, 0x00>>, 5) <> <<0x61, 0xC4, 0x11, 0x5A, 0xF1, 0x00>>

      gas_used_with_child = fn child_code ->
        db =
          db_with_sender()
          |> Database.put_code(@recipient, parent_code)
          |> Database.put_code(0xC411, child_code)
          |> Database.storage_store(0xC411, 0, 2)

        {:ok, result} = run(legacy_value_transfer(gas_limit: 100_000), db)
        assert result.status == :success
        result.gas_used
      end

      clearing = gas_used_with_child.(<<0x60, 0x00, 0x60, 0x00, 0x55, 0x00>>)
      resetting = gas_used_with_child.(<<0x60, 0x03, 0x60, 0x00, 0x55, 0x00>>)

      assert resetting - clearing == 4_800
    end

    test "a child frame can take its refund counter below zero" do
      # ethereum/tests SstoreCallToSelfSubRefundBelowZero. Slot 1 holds 2. The
      # top frame clears it (+4_800), then CALLs itself; the child writes 3,
      # undoing that refund (-4_800) from a counter that starts at 0.
      code = Base.decode16!("3330146015576000600155600080808080305AF1005B600360015500")

      db =
        db_with_sender()
        |> Database.put_code(@recipient, code)
        |> Database.storage_store(@recipient, 1, 2)

      assert {:ok, result} = run(legacy_value_transfer(gas_limit: 100_000), db)
      assert result.status == :success
      assert result.gas_used == 26_272
      assert Database.storage_load(result.db, @recipient, 1) == 3
    end

    test "a creation tx counts the code deposit toward the refund cap" do
      # Initcode: SSTORE(0, 1); SSTORE(0, 0) (earns 19_900); RETURN 10 zero bytes.
      # Intrinsic 21_000 + 32_000 + 192 calldata + 2 initcode = 53_194; execution
      # 22_106 + 106 + 9 = 22_221; code deposit 10 * 200 = 2_000. The cap is
      # 77_415 / 5 = 15_483. Settling before the deposit would cap at 15_083.
      initcode =
        <<0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0x55, 0x60, 0x0A, 0x60, 0x00,
          0xF3>>

      assert {:ok, result} = run(create_tx(initcode, 0), db_with_sender())
      assert result.status == :success
      assert result.gas_used == 77_415 - 15_483
    end
  end

  describe "execute/4 — logs" do
    test "returns logs from nested frames in emission order" do
      log1 = fn topic -> <<0x60, topic, 0x60, 0x00, 0x60, 0x00, 0xA1>> end
      # CALL(gas, 0xC0DE, 0, 0, 0, 0, 0); POP
      call = <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x61, 0xC0, 0xDE>>
      code = log1.(1) <> call <> <<0x5A, 0xF1, 0x50>> <> log1.(4) <> <<0x00>>
      child_code = log1.(2) <> log1.(3) <> <<0x00>>

      db =
        db_with_sender()
        |> Database.put_code(@recipient, code)
        |> Database.put_code(0xC0DE, child_code)

      assert {:ok, result} = run(legacy_value_transfer(gas_limit: 100_000, value: 0), db)
      assert result.status == :success

      assert Enum.map(result.logs, &{&1.address, &1.topics}) == [
               {@recipient, [1]},
               {0xC0DE, [2]},
               {0xC0DE, [3]},
               {@recipient, [4]}
             ]
    end
  end

  describe "execute/4 — REVERT" do
    test "marks status :revert and emits no logs" do
      # PUSH1 0 PUSH1 0 REVERT
      revert_code = <<0x60, 0x00, 0x60, 0x00, 0xFD>>

      db =
        db_with_sender(balance: 10_000_000)
        |> Database.put_code(@recipient, revert_code)

      tx = legacy_value_transfer(gas_limit: 50_000, value: 0)

      assert {:ok, result} = run(tx, db)
      assert result.status == :revert
      assert result.logs == []
      assert result.return_data == <<>>
      # Sender's nonce was still bumped despite the revert.
      assert Database.get_nonce(result.db, sender_address()) == 1
    end
  end

  describe "execute/4 — EIP-7702 set-code" do
    test "delegates the authority and runs the delegate's code in its context" do
      authority = authority_address()
      # ADDRESS PUSH1 0 SSTORE STOP
      db = db_with_sender() |> Database.put_code(@delegate, <<0x30, 0x60, 0x00, 0x55, 0x00>>)

      assert {:ok, result} = run_prague(set_code_tx([authorize(@delegate, 0)]), db)

      assert result.status == :success
      post = result.db
      assert Database.get_code(post, authority) == Delegation.designator(@delegate)
      assert Database.get_nonce(post, authority) == 1
      assert Database.storage_load(post, authority, 0) == authority
      assert Database.storage_load(post, @delegate, 0) == 0
      # 21_000 base + 25_000 authorization + ADDRESS, PUSH1, cold SSTORE 0 -> nonzero.
      # The authority did not exist before, so nothing is refunded.
      assert result.gas_used == 46_000 + 2 + 3 + 22_100
    end

    test "refunds 12,500 per existing authority, capped at a fifth of all gas used" do
      db = db_with_sender() |> Database.put_code(@delegate, <<0x00>>)
      tx = set_code_tx([authorize(@delegate, 0)])

      assert {:ok, %{gas_used: 46_000}} = run_prague(tx, db)

      existing = Database.set_balance(db, authority_address(), 1)
      # The cap counts intrinsic gas: min(12_500, 46_000 / 5) = 9_200.
      assert {:ok, %{gas_used: 36_800}} = run_prague(tx, existing)
    end

    test "skips invalid tuples without failing the transaction" do
      authority = authority_address()
      valid = authorize(@delegate, 0, 0)

      tuples = [
        authorize(0xBAD, 0, 5),
        authorize(0xBAD, 1),
        %{valid | s: @secp256k1n - valid.s, y_parity: 1 - valid.y_parity},
        valid,
        # Replays the nonce the previous tuple consumed.
        authorize(0xBAD, 0)
      ]

      assert {:ok, result} = run_prague(set_code_tx(tuples), db_with_sender())

      assert result.status == :success
      assert result.gas_used == 21_000 + 5 * 25_000

      assert Database.get_code(result.db, authority) ==
               Delegation.designator(@delegate)

      assert Database.get_nonce(result.db, authority) == 1
    end

    test "keeps delegations when execution reverts, and clears them for the zero address" do
      authority = authority_address()
      # PUSH1 0 PUSH1 0 REVERT
      db = db_with_sender() |> Database.put_code(@delegate, <<0x60, 0x00, 0x60, 0x00, 0xFD>>)

      assert {:ok, reverted} = run_prague(set_code_tx([authorize(@delegate, 0)]), db)
      assert reverted.status == :revert

      assert Database.get_code(reverted.db, authority) ==
               Delegation.designator(@delegate)

      clear = set_code_tx([authorize(0, 1)], nonce: 1)
      assert {:ok, cleared} = run_prague(clear, reverted.db)
      assert Database.get_code(cleared.db, authority) == <<>>
      assert Database.get_nonce(cleared.db, authority) == 2
    end

    test "decodes and executes wire bytes, but not before Prague" do
      bytes = [authorize(@delegate, 0)] |> set_code_tx() |> Envelope.encode()

      assert {:ok, %{status: :success}} = run_prague(bytes, db_with_sender())
      assert {:error, :tx_type_not_supported} = run(bytes, db_with_sender())
    end
  end

  describe "execute/4 — result status, receipt, and trace" do
    test "returns the receipt as an EEVM.Block.Receipt of the transaction's type" do
      # LOG0 of one byte at memory 0: PUSH1 1 PUSH1 0 LOG0 STOP.
      db = Database.put_code(db_with_sender(), @recipient, <<0x60, 1, 0x60, 0, 0xA0, 0x00>>)
      config = Config.new(:cancun, chain_id: @chain_id)

      {:ok, tx} =
        Signer.sign(
          %FeeMarket{
            to: @recipient,
            gas_limit: 50_000,
            max_fee_per_gas: 1,
            max_priority_fee_per_gas: 0
          },
          @priv_key,
          config
        )

      assert {:ok, result} = Handler.execute(tx, simple_block(), db, config: config)
      assert %Receipt{tx_type: :eip1559, status: 1} = result.receipt
      assert result.receipt.cumulative_gas_used == result.gas_used
      assert result.receipt.logs == [%{address: @recipient, topics: [], data: <<0>>}]
      assert result.receipt.logs_bloom == Bloom.from_logs(result.logs)

      assert {:ok, %{receipt: %Receipt{tx_type: :legacy}}} =
               run(legacy_value_transfer(gas_limit: 50_000), db)
    end

    test "an exceptional halt reports its reason, consumes all gas, and fails the receipt" do
      db = Database.put_code(db_with_sender(), @recipient, <<0xFE>>)

      assert {:ok, result} = run(legacy_value_transfer(gas_limit: 50_000), db)
      assert result.status == {:halt, :invalid_opcode}
      assert result.gas_used == 50_000
      assert result.receipt.status == 0
    end

    # EIP-170: deployed code may be at most 24,576 bytes. Code of exactly the
    # limit passes the size check and then can't pay its 200-gas-per-byte
    # deposit from 200,000 gas.
    test "a creation over the code size limit halts with :code_size_limit_exceeded" do
      # PUSH2 size PUSH1 0 RETURN: returns `size` zero bytes.
      deploy = fn size -> <<0x61, size::16, 0x60, 0x00, 0xF3>> end

      assert {:ok, %{status: {:halt, :code_size_limit_exceeded}, contract_address: nil}} =
               run(create_tx(deploy.(24_577), 0), db_with_sender())

      assert {:ok, %{status: {:halt, :out_of_gas}}} =
               run(create_tx(deploy.(24_576), 0), db_with_sender())
    end

    # EIP-3541 (London): deployed code may not start with 0xEF.
    test "a creation deploying 0xEF-prefixed code halts with :invalid_code_prefix" do
      # PUSH1 0xEF PUSH1 0 MSTORE8 PUSH1 1 PUSH1 0 RETURN
      initcode = <<0x60, 0xEF, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xF3>>

      assert {:ok, %{status: {:halt, :invalid_code_prefix}}} =
               run(create_tx(initcode, 0), db_with_sender())
    end

    test "tracer: true returns the trace of the top-level call; it is nil otherwise" do
      # PUSH1 1 PUSH1 0 SSTORE STOP
      db = Database.put_code(db_with_sender(), @recipient, <<0x60, 1, 0x60, 0, 0x55, 0x00>>)
      tx = legacy_value_transfer(gas_limit: 50_000)
      config = Config.new(:cancun, chain_id: @chain_id)

      assert {:ok, %{trace: %Tracer{} = trace}} =
               EEVM.transact(tx, simple_block(), db, config: config, tracer: true)

      assert Enum.map(Tracer.steps(trace), & &1.op) == [:PUSH1, :PUSH1, :SSTORE, :STOP]
      assert {:ok, %{trace: nil}} = run(tx, db)
    end
  end

  defp run(tx, db, block \\ simple_block()) do
    Handler.execute(tx, block, db, config: Config.new(:cancun, chain_id: @chain_id))
  end

  defp run_fork(tx, db, fork) do
    Handler.execute(tx, simple_block(), db, config: Config.new(fork, chain_id: @chain_id))
  end

  defp run_prague(tx, db) do
    Handler.execute(tx, simple_block(), db, config: Config.new(:prague, chain_id: @chain_id))
  end

  defp set_code_tx(authorizations, opts \\ []) do
    tx = %SetCode{
      chain_id: @chain_id,
      nonce: Keyword.get(opts, :nonce, 0),
      max_priority_fee_per_gas: 0,
      max_fee_per_gas: 1,
      gas_limit: 500_000,
      to: authority_address(),
      value: 0,
      data: <<>>,
      access_list: [],
      authorization_list: authorizations,
      y_parity: 0,
      r: 0,
      s: 0
    }

    {y_parity, r, s} = sign(Signer.signing_hash(tx, @chain_id), @priv_key)
    %{tx | y_parity: y_parity, r: r, s: s}
  end

  defp authorize(address, nonce, chain_id \\ @chain_id) do
    message =
      ExRLP.encode([encode_uint(chain_id), <<address::unsigned-big-160>>, encode_uint(nonce)])

    {y_parity, r, s} = sign(Keccak.hash_256(<<0x05>> <> message), @authority_key)

    %Authorization{
      chain_id: chain_id,
      address: address,
      nonce: nonce,
      y_parity: y_parity,
      r: r,
      s: s
    }
  end

  defp encode_uint(0), do: <<>>
  defp encode_uint(value), do: :binary.encode_unsigned(value)

  defp sign(hash, key) do
    {:ok, {<<r::unsigned-big-256, s::unsigned-big-256>>, recovery_id}} =
      ExSecp256k1.sign_compact(hash, key)

    {recovery_id, r, s}
  end

  defp authority_address, do: address_of(@authority_key)

  defp legacy_value_transfer(opts) do
    sign_legacy(
      %Legacy{
        nonce: Keyword.get(opts, :nonce, 0),
        gas_price: Keyword.get(opts, :gas_price, 1),
        gas_limit: Keyword.get(opts, :gas_limit, 21_000),
        to: Keyword.get(opts, :to, @recipient),
        value: Keyword.get(opts, :value, 0),
        data: Keyword.get(opts, :data, <<>>),
        v: 0,
        r: 0,
        s: 0
      },
      @chain_id
    )
  end

  defp create_tx(initcode, value) do
    legacy_value_transfer(to: nil, data: initcode, value: value, gas_limit: 200_000)
  end

  defp sign_legacy(%Legacy{} = tx, chain_id) do
    hash = Signer.signing_hash(tx, chain_id)

    {:ok, {<<r::unsigned-big-256, s::unsigned-big-256>>, recovery_id}} =
      ExSecp256k1.sign_compact(hash, @priv_key)

    %{tx | v: 35 + 2 * chain_id + recovery_id, r: r, s: s}
  end

  # A pre-EIP-155 signature (v = 27 or 28), as forks before Spurious Dragon require.
  defp pre_eip155_legacy(fields) do
    tx = struct!(%Legacy{nonce: 0, gas_price: 1, value: 0, data: <<>>, v: 27, r: 0, s: 0}, fields)
    hash = Signer.signing_hash(tx, nil)

    {:ok, {<<r::unsigned-big-256, s::unsigned-big-256>>, recovery_id}} =
      ExSecp256k1.sign_compact(hash, @priv_key)

    %{tx | v: 27 + recovery_id, r: r, s: s}
  end

  defp sign_eip1559(%FeeMarket{} = tx) do
    hash = Signer.signing_hash(tx, tx.chain_id)

    {:ok, {<<r::unsigned-big-256, s::unsigned-big-256>>, recovery_id}} =
      ExSecp256k1.sign_compact(hash, @priv_key)

    %{tx | y_parity: recovery_id, r: r, s: s}
  end

  defp blob_tx do
    tx = %Blob{
      chain_id: @chain_id,
      nonce: 0,
      max_priority_fee_per_gas: 2,
      max_fee_per_gas: 10,
      gas_limit: 21_000,
      to: @recipient,
      value: 0,
      data: <<>>,
      access_list: [],
      max_fee_per_blob_gas: 4,
      blob_versioned_hashes: [<<1, 1::248>>, <<1, 2::248>>],
      y_parity: 0,
      r: 0,
      s: 0
    }

    hash = Signer.signing_hash(tx, tx.chain_id)

    {:ok, {<<r::unsigned-big-256, s::unsigned-big-256>>, recovery_id}} =
      ExSecp256k1.sign_compact(hash, @priv_key)

    %{tx | y_parity: recovery_id, r: r, s: s}
  end

  defp sender_address, do: address_of(@priv_key)

  defp address_of(private_key) do
    {:ok, <<4, key::binary-size(64)>>} = ExSecp256k1.create_public_key(private_key)
    <<_::binary-size(12), address::binary-size(20)>> = Keccak.hash_256(key)
    :binary.decode_unsigned(address)
  end

  defp db_with_sender(opts \\ []) do
    balance = Keyword.get(opts, :balance, 1_000_000_000)
    nonce = Keyword.get(opts, :nonce, 0)

    InMemory.new(accounts: %{sender_address() => %{balance: balance, nonce: nonce, code: <<>>}})
  end

  defp simple_block(overrides \\ []) do
    BlockEnv.new(
      [gas_limit: 30_000_000, base_fee: 0, blob_base_fee: 0, coinbase: @coinbase] ++ overrides
    )
  end
end
