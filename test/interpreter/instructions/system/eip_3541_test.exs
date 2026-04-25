defmodule EEVM.Interpreter.Instructions.System.EIP3541Test do
  use ExUnit.Case, async: true

  import EEVM.TestSupport.BytecodeHelpers

  alias EEVM.{Database, WorldState}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Builds init code (bytecode) that, when executed, stores `runtime_code` in
  # memory byte-by-byte and then RETURNs it as the deployed runtime code.
  defp init_code_returning(runtime_code) do
    stores =
      runtime_code
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {byte, offset} ->
        IO.iodata_to_binary([push(byte), push(offset), <<0x53>>])
      end)

    IO.iodata_to_binary([
      stores,
      push(byte_size(runtime_code)),
      push(0),
      <<0xF3>>
    ])
  end

  defp push(0), do: <<0x60, 0x00>>
  defp push(n) when n <= 0xFF, do: <<0x60, n>>
  defp push(n) when n <= 0xFFFF, do: <<0x61, n::unsigned-big-16>>

  # ---------------------------------------------------------------------------
  # EIP-3541 rejection tests
  # ---------------------------------------------------------------------------

  describe "EIP-3541 runtime prefix rejection" do
    test "CREATE rejects runtime code starting with 0xEF — returns 0, no code stored" do
      init_code = init_code_returning(<<0xEF, 0xAA>>)
      code = build_create_program(init_code, :create, 0)
      initial_gas = 300_000

      result =
        EEVM.execute(code,
          gas: initial_gas,
          world_state: WorldState.new(%{0 => %{balance: 10}})
        )

      # CREATE pushes 0 to signal failed deployment
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]

      # Gas was consumed by init code execution (rejection does not refund it)
      assert result.gas < initial_gas

      # Nonce was incremented (sender nonce advances before deployment attempt)
      assert Database.get_nonce(result.db, 0) == 1

      # The sender's own code slot is empty — nothing was deployed
      assert Database.get_code(result.db, 0) == <<>>
    end

    test "CREATE2 rejects runtime code starting with 0xEF — returns 0" do
      init_code = init_code_returning(<<0xEF, 0xBB>>)
      code = build_create_program(init_code, :create2, 0, 1)

      result = EEVM.execute(code, world_state: WorldState.new(%{0 => %{balance: 10}}))

      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "CREATE allows empty runtime code — deployment succeeds" do
      # RETURN(0, 0) — returns zero bytes, i.e. empty runtime code
      init_code = <<0x60, 0x00, 0x60, 0x00, 0xF3>>
      code = build_create_program(init_code, :create, 0)

      result = EEVM.execute(code, world_state: WorldState.new(%{0 => %{balance: 10}}))
      [created_address] = EEVM.stack_values(result)

      assert result.status == :stopped
      assert created_address != 0
      assert Database.get_code(result.db, created_address) == <<>>
    end

    test "CREATE allows runtime code that does not start with 0xEF" do
      runtime_code = <<0x60, 0x00>>
      init_code = init_code_returning(runtime_code)
      code = build_create_program(init_code, :create, 0)

      result = EEVM.execute(code, world_state: WorldState.new(%{0 => %{balance: 10}}))
      [created_address] = EEVM.stack_values(result)

      assert result.status == :stopped
      assert created_address != 0
      assert Database.get_code(result.db, created_address) == runtime_code
    end

    test "0xEF bytes inside init code do not trigger rejection — only runtime prefix matters" do
      # Init code: PUSH1 0xEF, POP (uses 0xEF as data but returns non-0xEF runtime)
      ef_using_prefix = <<0x60, 0xEF, 0x50>>
      safe_runtime = <<0x60, 0x00>>
      init_code = ef_using_prefix <> init_code_returning(safe_runtime)
      code = build_create_program(init_code, :create, 0)

      result = EEVM.execute(code, world_state: WorldState.new(%{0 => %{balance: 10}}))
      [created_address] = EEVM.stack_values(result)

      assert result.status == :stopped
      assert created_address != 0
      assert Database.get_code(result.db, created_address) == safe_runtime
    end
  end
end
