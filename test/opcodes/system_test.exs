defmodule EEVM.Opcodes.SystemTest do
  use ExUnit.Case, async: true

  import EEVM.TestSupport.BytecodeHelpers

  alias EEVM.{Memory, Storage, WorldState}
  alias EEVM.Context.Contract

  describe "Executor - Return & Halt" do
    test "RETURN returns data from memory" do
      code = <<0x60, 0xAB, 0x60, 0, 0x53, 0x60, 1, 0x60, 0, 0xF3>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert result.return_data == <<0xAB>>
    end

    test "REVERT halts with :reverted" do
      code = <<0x60, 0, 0x60, 0, 0xFD>>
      result = EEVM.execute(code)
      assert result.status == :reverted
    end

    test "INVALID halts with :invalid" do
      code = <<0xFE>>
      result = EEVM.execute(code)
      assert result.status == :invalid
    end

    test "implicit STOP at end of code" do
      code = <<0x60, 5>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [5]
    end
  end

  describe "CREATE and CREATE2" do
    test "CREATE deploys runtime code and pushes created address" do
      init_code = <<0x60, 0xAA, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xF3>>
      code = build_create_program(init_code, :create, 0x00)

      result = EEVM.execute(code, world_state: WorldState.new(%{0 => %{balance: 10}}))
      [created_address] = EEVM.stack_values(result)

      assert result.status == :stopped
      assert created_address != 0
      assert WorldState.get_code(result.world_state, created_address) == <<0xAA>>
      assert WorldState.get_nonce(result.world_state, 0) == 1
    end

    test "CREATE transfers value to created contract" do
      init_code = <<0x60, 0x00, 0x60, 0x00, 0xF3>>
      code = build_create_program(init_code, :create, 0x02)

      result = EEVM.execute(code, world_state: WorldState.new(%{0 => %{balance: 7}}))
      [created_address] = EEVM.stack_values(result)

      assert WorldState.get_balance(result.world_state, 0) == 5
      assert WorldState.get_balance(result.world_state, created_address) == 2
    end

    test "CREATE2 with same salt and init code yields deterministic address" do
      init_code = <<0x60, 0xBB, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xF3>>
      code = build_create_program(init_code, :create2, 0x00, 0x01)

      result1 = EEVM.execute(code, world_state: WorldState.new(%{0 => %{balance: 10}}))
      result2 = EEVM.execute(code, world_state: WorldState.new(%{0 => %{balance: 10}}))

      [address1] = EEVM.stack_values(result1)
      [address2] = EEVM.stack_values(result2)

      assert address1 != 0
      assert address1 == address2
      assert WorldState.get_code(result1.world_state, address1) == <<0xBB>>
    end

    test "CREATE fails and pushes zero when balance is insufficient" do
      init_code = <<0x60, 0x00, 0x60, 0x00, 0xF3>>
      code = build_create_program(init_code, :create, 0x09)

      result = EEVM.execute(code, world_state: WorldState.new(%{0 => %{balance: 1}}))

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
      assert WorldState.get_balance(result.world_state, 0) == 1
    end
  end

  describe "CALL (0xF1)" do
    test "calls external code and pushes success flag" do
      child_code = <<0x60, 0x2A, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xF3>>

      world_state =
        WorldState.new(%{
          0 => %{balance: 10},
          1 => %{balance: 0, code: child_code}
        })

      code =
        <<0x60, 0x01, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x60, 0x64,
          0xF1, 0x00>>

      result = EEVM.execute(code, world_state: world_state)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [1]
      assert result.return_data == <<0x2A>>
      {mem, _} = Memory.read_bytes(result.memory, 0, 1)
      assert mem == <<0x2A>>
    end

    test "pushes failure flag when caller has insufficient balance" do
      world_state = WorldState.new(%{0 => %{balance: 0}, 1 => %{balance: 0, code: <<0x00>>}})

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x60, 0x01, 0x60, 0x64,
          0xF1, 0x00>>

      result = EEVM.execute(code, world_state: world_state)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
      assert WorldState.get_balance(result.world_state, 0) == 0
      assert WorldState.get_balance(result.world_state, 1) == 0
    end

    test "transfers value on successful call" do
      world_state = WorldState.new(%{0 => %{balance: 9}, 1 => %{balance: 0, code: <<0x00>>}})

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x03, 0x60, 0x01, 0x60, 0x64,
          0xF1, 0x00>>

      result = EEVM.execute(code, world_state: world_state)

      assert EEVM.stack_values(result) == [1]
      assert WorldState.get_balance(result.world_state, 0) == 6
      assert WorldState.get_balance(result.world_state, 1) == 3
    end

    test "failed child call pushes 0 and restores balances" do
      child_code = <<0x60, 0x00, 0x60, 0x00, 0xFD>>

      world_state =
        WorldState.new(%{
          0 => %{balance: 8},
          1 => %{balance: 1, code: child_code}
        })

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x02, 0x60, 0x01, 0x60, 0x64,
          0xF1, 0x00>>

      result = EEVM.execute(code, world_state: world_state)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
      assert WorldState.get_balance(result.world_state, 0) == 8
      assert WorldState.get_balance(result.world_state, 1) == 1
      assert result.return_data == <<>>
    end
  end

  describe "STATICCALL (0xFA)" do
    test "calls external code in static mode and pushes success flag" do
      child_code = <<0x60, 0x2A, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xF3>>

      world_state =
        WorldState.new(%{
          0 => %{balance: 10},
          1 => %{balance: 0, code: child_code}
        })

      code =
        <<0x60, 0x01, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x60, 0x64, 0xFA, 0x00>>

      result = EEVM.execute(code, world_state: world_state)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [1]
      assert result.return_data == <<0x2A>>
      {mem, _} = Memory.read_bytes(result.memory, 0, 1)
      assert mem == <<0x2A>>
    end

    test "pushes failure flag when child attempts SSTORE in static context" do
      child_code = <<0x60, 0x01, 0x60, 0x00, 0x55, 0x00>>

      world_state =
        WorldState.new(%{
          0 => %{balance: 10},
          1 => %{balance: 0, code: child_code}
        })

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x60, 0x64, 0xFA, 0x00>>

      result = EEVM.execute(code, world_state: world_state)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
      assert EEVM.Storage.load(result.storage, 0) == 0
    end

    test "pushes failure flag when child attempts LOG in static context" do
      child_code = <<0x60, 0x00, 0x60, 0x00, 0xA0, 0x00>>

      world_state =
        WorldState.new(%{
          0 => %{balance: 10},
          1 => %{balance: 0, code: child_code}
        })

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x60, 0x64, 0xFA, 0x00>>

      result = EEVM.execute(code, world_state: world_state)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "propagates static mode to nested calls" do
      grandchild_code = <<0x60, 0x01, 0x60, 0x00, 0x55, 0x00>>

      child_code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x02, 0x61, 0x75,
          0x30, 0xF1, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xF3>>

      world_state =
        WorldState.new(%{
          0 => %{balance: 10},
          1 => %{balance: 0, code: child_code},
          2 => %{balance: 0, code: grandchild_code}
        })

      code =
        <<0x60, 0x01, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x61, 0xC3, 0x50, 0xFA,
          0x00>>

      result = EEVM.execute(code, world_state: world_state)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [1]
      assert result.return_data == <<0x00>>
      {mem, _} = Memory.read_bytes(result.memory, 0, 1)
      assert mem == <<0x00>>
      assert EEVM.Storage.load(result.storage, 0) == 0
    end

    test "does not transfer value" do
      world_state = WorldState.new(%{0 => %{balance: 9}, 1 => %{balance: 0, code: <<0x00>>}})

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x60, 0x64, 0xFA, 0x00>>

      result = EEVM.execute(code, world_state: world_state)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [1]
      assert WorldState.get_balance(result.world_state, 0) == 9
      assert WorldState.get_balance(result.world_state, 1) == 0
    end
  end

  describe "DELEGATECALL (0xF4)" do
    test "runs target code in caller's storage context" do
      child_code = <<0x60, 0x01, 0x30, 0x55, 0x00>>

      world_state =
        WorldState.new(%{
          1 => %{code: child_code}
        })

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x61, 0xFF, 0xFF, 0xF4,
          0x00>>

      contract = Contract.new(address: 0xAA, caller: 0xBEEF, callvalue: 999)
      result = EEVM.execute(code, world_state: world_state, contract: contract)

      assert EEVM.stack_values(result) == [1]
      assert Storage.load(result.storage, 0xAA) == 1
      assert Storage.load(result.storage, 0x01) == 0
    end

    test "preserves caller (msg.sender)" do
      child_code = <<0x33, 0x60, 0x00, 0x55, 0x00>>
      world_state = WorldState.new(%{1 => %{code: child_code}})

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x61, 0xFF, 0xFF, 0xF4,
          0x00>>

      contract = Contract.new(address: 0xAA, caller: 0xBEEF, callvalue: 999)
      result = EEVM.execute(code, world_state: world_state, contract: contract)

      assert EEVM.stack_values(result) == [1]
      assert Storage.load(result.storage, 0) == 0xBEEF
    end

    test "preserves callvalue (msg.value)" do
      child_code = <<0x34, 0x60, 0x00, 0x55, 0x00>>
      world_state = WorldState.new(%{1 => %{code: child_code}})

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x61, 0xFF, 0xFF, 0xF4,
          0x00>>

      contract = Contract.new(address: 0xAA, caller: 0xBEEF, callvalue: 999)
      result = EEVM.execute(code, world_state: world_state, contract: contract)

      assert EEVM.stack_values(result) == [1]
      assert Storage.load(result.storage, 0) == 999
    end

    test "ADDRESS returns parent's address" do
      child_code = <<0x30, 0x60, 0x00, 0x55, 0x00>>
      world_state = WorldState.new(%{1 => %{code: child_code}})

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x61, 0xFF, 0xFF, 0xF4,
          0x00>>

      contract = Contract.new(address: 0xAA, caller: 0xBEEF, callvalue: 999)
      result = EEVM.execute(code, world_state: world_state, contract: contract)

      assert EEVM.stack_values(result) == [1]
      assert Storage.load(result.storage, 0) == 0xAA
    end

    test "pushes 0 on failure" do
      child_code = <<0x60, 0x00, 0x60, 0x00, 0xFD>>
      world_state = WorldState.new(%{1 => %{code: child_code}})

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x60, 0x64, 0xF4, 0x00>>

      result = EEVM.execute(code, world_state: world_state)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
      assert result.return_data == <<>>
    end
  end

  describe "CALLCODE (0xF2)" do
    test "runs target code in caller's storage context" do
      child_code = <<0x60, 0x01, 0x30, 0x55, 0x00>>
      world_state = WorldState.new(%{1 => %{code: child_code}})

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x61, 0xFF,
          0xFF, 0xF2, 0x00>>

      contract = Contract.new(address: 0xAA, caller: 0xBEEF)
      result = EEVM.execute(code, world_state: world_state, contract: contract)

      assert EEVM.stack_values(result) == [1]
      assert Storage.load(result.storage, 0xAA) == 1
      assert Storage.load(result.storage, 0x01) == 0
    end

    test "CALLER returns current contract address" do
      child_code = <<0x33, 0x60, 0x00, 0x55, 0x00>>
      world_state = WorldState.new(%{1 => %{code: child_code}})

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x61, 0xFF,
          0xFF, 0xF2, 0x00>>

      contract = Contract.new(address: 0xAAAA, caller: 0xBBBB)
      result = EEVM.execute(code, world_state: world_state, contract: contract)

      assert EEVM.stack_values(result) == [1]
      assert Storage.load(result.storage, 0) == 0xAAAA
    end

    test "pushes 0 on failure" do
      child_code = <<0x60, 0x00, 0x60, 0x00, 0xFD>>
      world_state = WorldState.new(%{1 => %{code: child_code}})

      code =
        <<0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x60, 0x64,
          0xF2, 0x00>>

      result = EEVM.execute(code, world_state: world_state)

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
      assert result.return_data == <<>>
    end
  end
end
