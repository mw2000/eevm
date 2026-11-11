defmodule EEVMTest do
  use ExUnit.Case, async: true
  doctest EEVM
  doctest_file(Path.expand("../README.md", __DIR__))

  describe "run/2" do
    alias EEVM.{BlockEnv, CallResult, Database, Tracer}
    alias EEVM.Database.InMemory

    test "returns RETURN data and the gas used" do
      # PUSH1 42 PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN: 5 pushes and MSTORE
      # at 3 gas each, plus 3 gas to expand memory to one word.
      code = <<0x60, 42, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xF3>>

      assert {:ok, %CallResult{status: :success} = result} = EEVM.run(code, gas: 100_000)
      assert :binary.decode_unsigned(result.return_data) == 42
      assert {result.gas_used, result.gas_left} == {18, 99_982}
      assert result.stack == nil and result.trace == nil
    end

    test "passes address, caller, value, and calldata to the code" do
      # PUSH1 0 CALLDATALOAD CALLVALUE CALLER ADDRESS STOP
      code = <<0x60, 0, 0x35, 0x34, 0x33, 0x30, 0x00>>

      assert {:ok, result} =
               EEVM.run(code,
                 address: 0xA,
                 caller: 0xCA11E2,
                 value: 7,
                 calldata: <<0x80, 0::248>>,
                 debug: true
               )

      assert result.stack == [0xA, 0xCA11E2, 7, 2 ** 255]
    end

    test "keeps state changes and logs only on success" do
      # PUSH1 1 PUSH1 0 SSTORE PUSH1 0 PUSH1 0 LOG0, then STOP or REVERT.
      body = <<0x60, 1, 0x60, 0, 0x55, 0x60, 0, 0x60, 0, 0xA0>>
      db = InMemory.new()

      assert {:ok, ok} = EEVM.run(body <> <<0x00>>, address: 0xA, db: db)
      assert Database.storage_load(ok.db, 0xA, 0) == 1
      assert ok.logs == [%{address: 0xA, topics: [], data: <<>>}]

      assert {:ok, reverted} = EEVM.run(body <> <<0x60, 0, 0x60, 0, 0xFD>>, address: 0xA, db: db)
      assert reverted.status == :revert
      assert Database.storage_load(reverted.db, 0xA, 0) == 0
      assert reverted.logs == []
      assert reverted.gas_left > 0
    end

    test "an exceptional halt consumes all gas and names its reason" do
      assert {:ok, %{status: {:halt, :stack_underflow}, gas_used: 500, gas_left: 0}} =
               EEVM.run(<<0x01>>, gas: 500)
    end

    # EIP-3855: PUSH0 exists from Shanghai.
    test "runs under the given hardfork" do
      assert {:ok, %{status: {:halt, :invalid_opcode}}} =
               EEVM.run(<<0x5F, 0x00>>, hardfork: :paris)

      assert {:ok, %{status: :success}} = EEVM.run(<<0x5F, 0x00>>, hardfork: :shanghai)
    end

    test "reads the block environment" do
      # NUMBER STOP
      assert {:ok, %{stack: [19]}} =
               EEVM.run(<<0x43, 0x00>>, block: BlockEnv.new(number: 19), debug: true)
    end

    test "tracer: true records one step per opcode" do
      assert {:ok, %{trace: %Tracer{} = trace}} =
               EEVM.run(<<0x60, 1, 0x60, 2, 0x01, 0x00>>, tracer: true)

      assert Enum.map(Tracer.steps(trace), & &1.op) == [:PUSH1, :PUSH1, :ADD, :STOP]
    end

    test "rejects an unknown option" do
      assert_raise ArgumentError, fn -> EEVM.run(<<0x00>>, contract: nil) end
    end
  end

  describe "call/4 and create/3" do
    alias EEVM.Database
    alias EEVM.Database.InMemory

    # Return storage slot 0 as a word: PUSH1 0 SLOAD PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN.
    @return_slot0 <<0x60, 0, 0x54, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xF3>>
    # ORIGIN CALLER CALLVALUE STOP, read with debug: true.
    @who <<0x32, 0x33, 0x34, 0x00>>
    # PUSH1 0xAB PUSH1 0 MSTORE8 PUSH1 1 PUSH1 0 REVERT
    @revert_ab <<0x60, 0xAB, 0x60, 0, 0x53, 0x60, 1, 0x60, 0, 0xFD>>

    # Initcode that copies `runtime` from its own tail and returns it.
    defp deployer(runtime) do
      size = byte_size(runtime)
      <<0x60, size, 0x60, 12, 0x60, 0, 0x39, 0x60, size, 0x60, 0, 0xF3>> <> runtime
    end

    test "call/4 runs the code stored at `to` against `to`'s storage, not address 0's" do
      db =
        InMemory.new(
          accounts: %{0xC0DE => %{code: @return_slot0}},
          storage: %{0 => %{0 => 7}, 0xC0DE => %{0 => 42}}
        )

      assert {:ok, result} = EEVM.call(db, 0xC0DE)
      assert {result.status, :binary.decode_unsigned(result.return_data)} == {:success, 42}
      assert result.contract_address == nil
    end

    test "call/4 impersonates any caller and moves value from it" do
      db = InMemory.new(accounts: %{0xA11CE => %{balance: 100}, 0xC0DE => %{code: @who}})

      assert {:ok, result} = EEVM.call(db, 0xC0DE, <<>>, caller: 0xA11CE, value: 30, debug: true)
      assert result.stack == [30, 0xA11CE, 0xA11CE]
      assert Database.get_balance(result.db, 0xA11CE) == 70
      assert Database.get_balance(result.db, 0xC0DE) == 30

      assert EEVM.call(db, 0xC0DE, <<>>, caller: 0xA11CE, value: 101) ==
               {:error, :insufficient_balance}
    end

    test "call/4 keeps the REVERT data and drops the writes of a reverted call" do
      db = InMemory.new(accounts: %{0xA11CE => %{balance: 100}, 0xC0DE => %{code: @revert_ab}})

      assert {:ok, result} = EEVM.call(db, 0xC0DE, <<>>, caller: 0xA11CE, value: 30)
      assert {result.status, result.return_data} == {:revert, <<0xAB>>}
      assert Database.get_balance(result.db, 0xA11CE) == 100
    end

    test "call/4 to a precompile runs it" do
      # 0x04 is IDENTITY.
      assert {:ok, result} = EEVM.call(InMemory.new(), 0x04, "hello")
      assert {result.status, result.return_data} == {:success, "hello"}
    end

    test "create/3 derives CREATE addresses from the caller's nonce and installs the code" do
      # keccak(rlp([sender, nonce]))[12:] for nonces 0 and 1, the widely cited
      # example from the Yellow Paper's section 7 formula.
      sender = 0x6AC7EA33F8831EA9DCC53393AAA88B25A785DBF0
      initcode = deployer(@return_slot0)

      assert {:ok, first} = EEVM.create(InMemory.new(), initcode, caller: sender)
      assert first.status == :success
      assert first.contract_address == 0xCD234A471B72BA2F1CCF0A70FCABA648A5EECD8D
      assert Database.get_code(first.db, first.contract_address) == @return_slot0

      assert {:ok, second} = EEVM.create(first.db, initcode, caller: sender)
      assert second.contract_address == 0x343C43A37D37DFF08AE8C4A11544C718ABB4FCF8
      assert Database.get_nonce(second.db, sender) == 2

      # The deployed contract is callable from the returned database.
      assert {:ok, %{status: :success}} = EEVM.call(second.db, second.contract_address)
    end

    test "a failed create/3 returns no address and leaves the database, nonce included" do
      db = InMemory.new(accounts: %{0xA11CE => %{nonce: 5}})

      assert {:ok, result} = EEVM.create(db, @revert_ab, caller: 0xA11CE)

      assert {result.status, result.return_data, result.contract_address} ==
               {:revert, <<0xAB>>, nil}

      assert Database.get_nonce(result.db, 0xA11CE) == 5
    end

    test "create/3 applies the EIP-3860 initcode limit from Shanghai only" do
      # STOP followed by padding: the initcode deploys empty code.
      at_limit = <<0x00>> <> :binary.copy(<<0>>, 49_151)
      over_limit = at_limit <> <<0>>
      db = InMemory.new()

      assert {:ok, %{status: :success}} = EEVM.create(db, at_limit, hardfork: :shanghai)
      assert EEVM.create(db, over_limit, hardfork: :shanghai) == {:error, :initcode_too_large}
      assert {:ok, %{status: :success}} = EEVM.create(db, over_limit, hardfork: :paris)
    end

    test "run/2 refuses a database without an address instead of reading address 0" do
      db = InMemory.new(storage: %{0 => %{0 => 7}})

      assert_raise ArgumentError, ~r/EEVM.call\/4/, fn -> EEVM.run(@return_slot0, db: db) end

      assert {:ok, result} = EEVM.run(@return_slot0, db: db, address: 0)
      assert :binary.decode_unsigned(result.return_data) == 7
    end
  end

  describe "address/1 and hex/1" do
    test "convert between hex, 20-byte binaries, and integer addresses" do
      address = 0x9D8A62F656A8D1615C1294FD71E9CFB3E4855A4F

      assert EEVM.address("0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f") == address
      assert EEVM.address("9D8A62F656A8D1615C1294FD71E9CFB3E4855A4F") == address
      assert EEVM.address(<<address::160>>) == address
      assert EEVM.hex(<<address::160>>) == "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f"
      assert EEVM.hex(<<1::160>>) == "0x0000000000000000000000000000000000000001"
    end

    test "address/1 rejects anything that isn't a 20-byte address" do
      for bad <- [
            "0x" <> String.duplicate("0", 38),
            "0x" <> String.duplicate("g", 40),
            <<1::152>>,
            2 ** 160
          ] do
        assert_raise ArgumentError, fn -> EEVM.address(bad) end
      end
    end
  end

  describe "Disassembler" do
    test "disassembles simple program" do
      code = <<0x60, 0x01, 0x60, 0x02, 0x01, 0x00>>
      result = EEVM.disassemble(code)

      assert result == [
               {0, "PUSH1", "0x01"},
               {2, "PUSH1", "0x02"},
               {4, "ADD", nil},
               {5, "STOP", nil}
             ]
    end
  end
end
