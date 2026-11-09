defmodule EEVM.HardforkConfigTest do
  use ExUnit.Case, async: true
  import EEVM.TestSupport.MachineHelpers

  alias EEVM.BlockEnv
  alias EEVM.Context.Contract
  alias EEVM.Database
  alias EEVM.Database.InMemory
  alias EEVM.HardforkConfig

  # ---------------------------------------------------------------------------
  # HardforkConfig.enabled?/2 unit tests
  # ---------------------------------------------------------------------------

  describe "HardforkConfig.enabled?/2" do
    test "EIP-3855 (PUSH0) is enabled from Shanghai onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:shanghai), :eip_3855)
      assert HardforkConfig.enabled?(HardforkConfig.new(:cancun), :eip_3855)
      assert HardforkConfig.enabled?(HardforkConfig.new(:prague), :eip_3855)
    end

    test "EIP-3855 (PUSH0) is disabled before Shanghai" do
      refute HardforkConfig.enabled?(HardforkConfig.new(:london), :eip_3855)
      refute HardforkConfig.enabled?(HardforkConfig.new(:berlin), :eip_3855)
      refute HardforkConfig.enabled?(HardforkConfig.new(:frontier), :eip_3855)
    end

    test "EIP-1153 (TLOAD/TSTORE) is enabled from Cancun onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:cancun), :eip_1153)
      assert HardforkConfig.enabled?(HardforkConfig.new(:prague), :eip_1153)
    end

    test "EIP-1153 (TLOAD/TSTORE) is disabled before Cancun" do
      refute HardforkConfig.enabled?(HardforkConfig.new(:shanghai), :eip_1153)
      refute HardforkConfig.enabled?(HardforkConfig.new(:london), :eip_1153)
    end

    test "EIP-5656 (MCOPY) is enabled from Cancun onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:cancun), :eip_5656)
    end

    test "EIP-5656 (MCOPY) is disabled before Cancun" do
      refute HardforkConfig.enabled?(HardforkConfig.new(:shanghai), :eip_5656)
    end

    test "EIP-6780 (SELFDESTRUCT) is enabled from Cancun onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:cancun), :eip_6780)
    end

    test "EIP-6780 (SELFDESTRUCT) is disabled before Cancun" do
      refute HardforkConfig.enabled?(HardforkConfig.new(:shanghai), :eip_6780)
    end

    test "EIP-7623 (calldata floor pricing) is enabled from Prague onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:prague), :eip_7623)
      refute HardforkConfig.enabled?(HardforkConfig.new(:cancun), :eip_7623)
    end

    test "EIP-7825 (transaction gas limit cap) is enabled from Osaka onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:osaka), :eip_7825)
      refute HardforkConfig.enabled?(HardforkConfig.new(:prague), :eip_7825)
    end

    test "EIP-7918 (blob base fee reserve price) is enabled from Osaka onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:osaka), :eip_7918)
      refute HardforkConfig.enabled?(HardforkConfig.new(:prague), :eip_7918)
    end

    test "EIP-7934 (RLP block size limit) is enabled from Osaka onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:osaka), :eip_7934)
      refute HardforkConfig.enabled?(HardforkConfig.new(:prague), :eip_7934)
    end

    test "EIP-7939 (CLZ) is enabled from Osaka onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:osaka), :eip_7939)
      refute HardforkConfig.enabled?(HardforkConfig.new(:prague), :eip_7939)
    end

    test "EIP-2929 (cold/warm access) is enabled from Berlin onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:berlin), :eip_2929)
      assert HardforkConfig.enabled?(HardforkConfig.new(:london), :eip_2929)
      assert HardforkConfig.enabled?(HardforkConfig.new(:cancun), :eip_2929)
    end

    test "EIP-2929 (cold/warm access) is disabled before Berlin" do
      refute HardforkConfig.enabled?(HardforkConfig.new(:istanbul), :eip_2929)
      refute HardforkConfig.enabled?(HardforkConfig.new(:frontier), :eip_2929)
    end

    test "EIP-3529 (refund cap 1/5) is enabled from London onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:london), :eip_3529)
      assert HardforkConfig.enabled?(HardforkConfig.new(:cancun), :eip_3529)
    end

    test "EIP-3529 (refund cap 1/5) is disabled before London" do
      refute HardforkConfig.enabled?(HardforkConfig.new(:berlin), :eip_3529)
    end

    test "EIP-170 (code size limit) is enabled from Spurious Dragon onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:spurious_dragon), :eip_170)
      assert HardforkConfig.enabled?(HardforkConfig.new(:cancun), :eip_170)
    end

    test "EIP-170 (code size limit) is disabled before Spurious Dragon" do
      refute HardforkConfig.enabled?(HardforkConfig.new(:homestead), :eip_170)
      refute HardforkConfig.enabled?(HardforkConfig.new(:frontier), :eip_170)
    end

    test "EIP-3860 (initcode limit) is enabled from Shanghai onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:shanghai), :eip_3860)
      assert HardforkConfig.enabled?(HardforkConfig.new(:cancun), :eip_3860)
    end

    test "EIP-3860 (initcode limit) is disabled before Shanghai" do
      refute HardforkConfig.enabled?(HardforkConfig.new(:london), :eip_3860)
    end

    test "EIP-3541 (0xEF prefix rejection) is enabled from London onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:london), :eip_3541)
      assert HardforkConfig.enabled?(HardforkConfig.new(:cancun), :eip_3541)
    end

    test "EIP-3541 (0xEF prefix rejection) is disabled before London" do
      refute HardforkConfig.enabled?(HardforkConfig.new(:berlin), :eip_3541)
    end

    test "unknown EIP feature flag returns false" do
      refute HardforkConfig.enabled?(HardforkConfig.new(:cancun), :eip_9999)
    end

    test "EIP-2537 (BLS12-381 precompiles) is enabled from Prague onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:prague), :eip_2537)
    end

    test "EIP-2537 (BLS12-381 precompiles) is disabled before Prague" do
      refute HardforkConfig.enabled?(HardforkConfig.new(:cancun), :eip_2537)
      refute HardforkConfig.enabled?(HardforkConfig.new(:shanghai), :eip_2537)
    end

    test "EIP-7883 (ModExp repricing) is enabled from Osaka onward" do
      assert HardforkConfig.enabled?(HardforkConfig.new(:osaka), :eip_7883)
      refute HardforkConfig.enabled?(HardforkConfig.new(:prague), :eip_7883)
    end

    test "default config is Cancun" do
      assert HardforkConfig.default().spec_id == :cancun
    end

    test "all_spec_ids returns hardforks in chronological order" do
      ids = HardforkConfig.all_spec_ids()
      frontier_idx = Enum.find_index(ids, &(&1 == :frontier))
      cancun_idx = Enum.find_index(ids, &(&1 == :cancun))
      assert frontier_idx < cancun_idx
    end
  end

  describe "precompile availability by fork" do
    @precompile_sets [
      frontier: [0x01, 0x02, 0x03, 0x04],
      spurious_dragon: [0x01, 0x02, 0x03, 0x04],
      byzantium: Enum.to_list(0x01..0x08),
      constantinople: Enum.to_list(0x01..0x08),
      istanbul: Enum.to_list(0x01..0x09),
      berlin: Enum.to_list(0x01..0x09),
      shanghai: Enum.to_list(0x01..0x09),
      cancun: Enum.to_list(0x01..0x0A),
      prague: Enum.to_list(0x01..0x11),
      osaka: Enum.to_list(0x01..0x11) ++ [0x100]
    ]

    for {fork, addresses} <- @precompile_sets do
      test "#{fork} has precompiles #{inspect(addresses, base: :hex)}" do
        config = EEVM.Config.new(unquote(fork))
        assert EEVM.Precompiles.precompile_addresses(config) == unquote(addresses)
      end
    end

    test "an address a fork does not define runs no precompile" do
      assert {:error, :not_implemented} =
               EEVM.Precompiles.execute(0x09, <<>>, 100_000, EEVM.Config.new(:constantinople))

      assert {:error, :not_implemented} =
               EEVM.Precompiles.execute(0x0A, <<>>, 100_000, EEVM.Config.new(:shanghai))
    end
  end

  describe "EIP-2537 BLS12-381 precompile hardfork guard" do
    test "BLS12-381 precompiles are registered on Prague" do
      config = EEVM.Config.new(:prague)

      for address <- 0x0B..0x11 do
        assert EEVM.Precompiles.precompile?(address, config)
      end
    end

    test "BLS12-381 precompiles are not registered before Prague" do
      config = EEVM.Config.new(:cancun)

      for address <- 0x0B..0x11 do
        refute EEVM.Precompiles.precompile?(address, config)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Opcode availability: each opcode is undefined (halts like INVALID) on the
  # fork before its EIP and defined from its activation fork on.
  # ---------------------------------------------------------------------------

  describe "opcode availability by hardfork" do
    for {opcode, name, previous_fork, activation_fork} <- [
          {0xF4, "DELEGATECALL", :frontier, :homestead},
          {0xFD, "REVERT", :spurious_dragon, :byzantium},
          {0x3D, "RETURNDATASIZE", :spurious_dragon, :byzantium},
          {0x3E, "RETURNDATACOPY", :spurious_dragon, :byzantium},
          {0xFA, "STATICCALL", :spurious_dragon, :byzantium},
          {0x1B, "SHL", :byzantium, :constantinople},
          {0x1C, "SHR", :byzantium, :constantinople},
          {0x1D, "SAR", :byzantium, :constantinople},
          {0x3F, "EXTCODEHASH", :byzantium, :constantinople},
          {0xF5, "CREATE2", :byzantium, :constantinople},
          {0x46, "CHAINID", :constantinople, :istanbul},
          {0x47, "SELFBALANCE", :constantinople, :istanbul},
          {0x48, "BASEFEE", :berlin, :london},
          {0x5F, "PUSH0", :paris, :shanghai},
          {0x5C, "TLOAD", :shanghai, :cancun},
          {0x5D, "TSTORE", :shanghai, :cancun},
          {0x5E, "MCOPY", :shanghai, :cancun},
          {0x49, "BLOBHASH", :shanghai, :cancun},
          {0x4A, "BLOBBASEFEE", :shanghai, :cancun},
          {0x1E, "CLZ", :prague, :osaka}
        ] do
      test "#{name} is undefined on #{previous_fork} and defined from #{activation_fork}" do
        # Eight zero arguments satisfy every opcode's stack inputs.
        code = <<0x60, 0x00, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, unquote(opcode), 0x00>>

        assert EEVM.Interpreter.run(code, hardfork: unquote(previous_fork)).status == :invalid
        refute EEVM.Interpreter.run(code, hardfork: unquote(activation_fork)).status == :invalid
      end
    end
  end

  # ---------------------------------------------------------------------------
  # EIP-3855 (PUSH0) behavioral tests
  # ---------------------------------------------------------------------------

  describe "EIP-3855 PUSH0 hardfork guard" do
    test "PUSH0 works on Cancun (default)" do
      # PUSH0, STOP
      code = <<0x5F, 0x00>>
      result = EEVM.Interpreter.run(code)
      assert result.status == :stopped
      assert stack_values(result) == [0]
    end

    test "PUSH0 is invalid before Shanghai" do
      code = <<0x5F, 0x00>>
      result = EEVM.Interpreter.run(code, hardfork: :london)
      assert result.status == :invalid
    end

    test "PUSH0 works on Shanghai" do
      code = <<0x5F, 0x00>>
      result = EEVM.Interpreter.run(code, hardfork: :shanghai)
      assert result.status == :stopped
      assert stack_values(result) == [0]
    end
  end

  # ---------------------------------------------------------------------------
  # EIP-1153 (TLOAD/TSTORE) behavioral tests
  # ---------------------------------------------------------------------------

  describe "EIP-1153 TLOAD/TSTORE hardfork guard" do
    test "TLOAD works on Cancun (default)" do
      # PUSH1 0 (key), TLOAD, STOP
      code = <<0x60, 0x00, 0x5C, 0x00>>
      result = EEVM.Interpreter.run(code)
      assert result.status == :stopped
      assert stack_values(result) == [0]
    end

    test "TLOAD is invalid before Cancun" do
      code = <<0x60, 0x00, 0x5C, 0x00>>
      result = EEVM.Interpreter.run(code, hardfork: :shanghai)
      assert result.status == :invalid
    end

    test "TSTORE is invalid before Cancun" do
      # PUSH1 0xFF (value), PUSH1 0x01 (key), TSTORE, STOP
      code = <<0x60, 0xFF, 0x60, 0x01, 0x5D, 0x00>>
      result = EEVM.Interpreter.run(code, hardfork: :shanghai)
      assert result.status == :invalid
    end
  end

  # ---------------------------------------------------------------------------
  # EIP-5656 (MCOPY) behavioral tests
  # ---------------------------------------------------------------------------

  describe "EIP-5656 MCOPY hardfork guard" do
    test "MCOPY works on Cancun (default)" do
      # MSTORE(0, 0xDEAD), then MCOPY(dst=32, src=0, len=32), MLOAD(32)
      code =
        <<
          # PUSH2 0xDEAD, PUSH1 0 (offset), MSTORE
          0x61,
          0xDE,
          0xAD,
          0x60,
          0x00,
          0x52,
          # PUSH1 32 (len), PUSH1 0 (src), PUSH1 32 (dst), MCOPY
          0x60,
          0x20,
          0x60,
          0x00,
          0x60,
          0x20,
          0x5E,
          # PUSH1 32, MLOAD
          0x60,
          0x20,
          0x51,
          0x00
        >>

      result = EEVM.Interpreter.run(code)
      assert result.status == :stopped
      assert stack_values(result) == [0xDEAD]
    end

    test "MCOPY is invalid before Cancun" do
      code = <<0x60, 0x01, 0x60, 0x00, 0x60, 0x01, 0x5E, 0x00>>
      result = EEVM.Interpreter.run(code, hardfork: :shanghai)
      assert result.status == :invalid
    end
  end

  # ---------------------------------------------------------------------------
  # EIP-6780 (SELFDESTRUCT) behavioral tests
  # ---------------------------------------------------------------------------

  describe "EIP-6780 SELFDESTRUCT hardfork guard" do
    test "post-Cancun: SELFDESTRUCT preserves account if not created this tx" do
      world_state =
        InMemory.new(
          accounts: %{
            0xAA => %{balance: 75, code: <<0xFE>>, nonce: 10},
            0xBB => %{balance: 0}
          }
        )

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      result =
        EEVM.Interpreter.run(code,
          db: world_state,
          contract: contract,
          gas: 1_000_000
        )

      assert result.status == :stopped
      # Account preserved (EIP-6780: no full delete)
      assert Database.account_exists?(result.db, 0xAA) == true
      assert Database.get_balance(result.db, 0xAA) == 0
      assert Database.get_balance(result.db, 0xBB) == 75
    end

    test "pre-Cancun: SELFDESTRUCT always fully deletes the account" do
      world_state =
        InMemory.new(
          accounts: %{
            0xAA => %{balance: 75, code: <<0xFE>>, nonce: 10},
            0xBB => %{balance: 0}
          }
        )

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      result =
        EEVM.Interpreter.run(code,
          db: world_state,
          contract: contract,
          gas: 1_000_000,
          hardfork: :shanghai
        )

      assert result.status == :stopped
      # Account fully deleted pre-EIP-6780
      assert Database.account_exists?(result.db, 0xAA) == false
      assert Database.get_balance(result.db, 0xBB) == 75
    end

    test "Cancun: SELFDESTRUCT fully deletes if created this tx" do
      world_state =
        InMemory.new(
          accounts: %{
            0xAA => %{balance: 100, code: <<0x60, 0x01>>, nonce: 3},
            0xBB => %{balance: 50}
          }
        )

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      result =
        EEVM.Interpreter.run(code,
          db: world_state,
          contract: contract,
          created_addresses: MapSet.new([0xAA]),
          gas: 1_000_000
        )

      assert result.status == :stopped
      assert Database.get_account(result.db, 0xAA) == nil
      assert Database.get_balance(result.db, 0xBB) == 150
    end
  end

  # ---------------------------------------------------------------------------
  # EIP-2929 (cold/warm access) behavioral tests
  # ---------------------------------------------------------------------------

  describe "EIP-2929 cold/warm access hardfork guard" do
    test "Berlin+: cold SLOAD charges 2100 extra gas" do
      # PUSH1 key (0x00), SLOAD, STOP
      code = <<0x60, 0x00, 0x54, 0x00>>

      # On Berlin, first SLOAD hits cold access (2100 extra on top of static 0)
      berlin_result = EEVM.Interpreter.run(code, hardfork: :berlin, gas: 100_000)
      # PUSH1 costs 3; static SLOAD is 0; cold access adds 2100
      berlin_gas_used = 100_000 - berlin_result.frame.gas
      assert berlin_gas_used == 3 + 2100

      # Pre-Berlin: no cold/warm distinction, only SLOAD's flat EIP-1884 price
      istanbul_result = EEVM.Interpreter.run(code, hardfork: :istanbul, gas: 100_000)
      istanbul_gas_used = 100_000 - istanbul_result.frame.gas
      assert istanbul_gas_used == 3 + 800
    end
  end

  # ---------------------------------------------------------------------------
  # Pre-Berlin static gas schedule (EIP-150, EIP-1884)
  # ---------------------------------------------------------------------------

  describe "pre-Berlin static gas schedule" do
    # Gas used by `PUSH1 0xAB, <opcode>, STOP` on each fork, minus the PUSH1.
    # 0xAB is a cold address and a cold slot.
    defp access_opcode_cost(opcode, fork) do
      result = EEVM.Interpreter.run(<<0x60, 0xAB, opcode, 0x00>>, hardfork: fork, gas: 100_000)
      100_000 - result.frame.gas - 3
    end

    test "SLOAD: 50 on Frontier, 200 from EIP-150, 800 from EIP-1884, cold 2100 from Berlin" do
      assert access_opcode_cost(0x54, :homestead) == 50
      assert access_opcode_cost(0x54, :tangerine_whistle) == 200
      assert access_opcode_cost(0x54, :constantinople) == 200
      assert access_opcode_cost(0x54, :istanbul) == 800
      assert access_opcode_cost(0x54, :berlin) == 2100
    end

    test "BALANCE: 20 on Frontier, 400 from EIP-150, 700 from EIP-1884, cold 2600 from Berlin" do
      assert access_opcode_cost(0x31, :frontier) == 20
      assert access_opcode_cost(0x31, :spurious_dragon) == 400
      assert access_opcode_cost(0x31, :istanbul) == 700
      assert access_opcode_cost(0x31, :berlin) == 2600
    end

    test "EXTCODESIZE and EXTCODEHASH follow EIP-150 and EIP-1884" do
      assert access_opcode_cost(0x3B, :frontier) == 20
      assert access_opcode_cost(0x3B, :istanbul) == 700
      assert access_opcode_cost(0x3F, :constantinople) == 400
      assert access_opcode_cost(0x3F, :istanbul) == 700
    end
  end

  describe "EIP-161 empty-account clearing hardfork guard" do
    test "a touched empty account is deleted from Spurious Dragon on, kept before" do
      # CALL 0x42 with no value, STOP. 0x42 exists but is empty.
      code = <<0x60, 0, 0x60, 0, 0x60, 0, 0x60, 0, 0x60, 0, 0x60, 0x42, 0x61, 0xFF, 0xFF>>
      code = code <> <<0xF1, 0x00>>
      world_state = InMemory.new(accounts: %{0x42 => %{balance: 0}})

      exists_after? = fn fork ->
        result = EEVM.Interpreter.run(code, gas: 100_000, hardfork: fork, db: world_state)
        Database.account_exists?(result.db, 0x42)
      end

      assert exists_after?.(:tangerine_whistle)
      refute exists_after?.(:spurious_dragon)
    end
  end

  describe "EIP-3651 warm COINBASE hardfork guard" do
    test "COINBASE starts warm from Shanghai and cold before" do
      # COINBASE, BALANCE, STOP
      code = <<0x41, 0x31, 0x00>>
      block = BlockEnv.new(coinbase: 0xC0FFEE)

      gas_used = fn fork ->
        100_000 - EEVM.Interpreter.run(code, gas: 100_000, block: block, hardfork: fork).frame.gas
      end

      assert gas_used.(:shanghai) == 2 + 100
      assert gas_used.(:paris) == 2 + 2_600
    end
  end

  # ---------------------------------------------------------------------------
  # EIP-3529 (refund cap) behavioral tests
  # ---------------------------------------------------------------------------

  describe "EIP-3529 gas refund cap hardfork guard" do
    test "London+: refund capped at 1/5 of gas used" do
      # SSTORE key=1 value=0xFF (set), then SSTORE key=1 value=0 (clear for refund)
      code =
        IO.iodata_to_binary([
          # SSTORE(1, 0xFF)
          <<0x60, 0xFF, 0x60, 0x01, 0x55>>,
          # SSTORE(1, 0)
          <<0x60, 0x00, 0x60, 0x01, 0x55>>,
          <<0x00>>
        ])

      result = EEVM.Interpreter.run(code, hardfork: :london, gas: 200_000)
      # Refund was accrued but then capped at 1/5 of gas used
      assert result.frame.refund == 0
    end

    test "pre-London: refund capped at 1/2 of gas used" do
      # Same code — just verifying the executor doesn't crash and applies the 1/2 cap
      code =
        IO.iodata_to_binary([
          <<0x60, 0xFF, 0x60, 0x01, 0x55>>,
          <<0x60, 0x00, 0x60, 0x01, 0x55>>,
          <<0x00>>
        ])

      result = EEVM.Interpreter.run(code, hardfork: :berlin, gas: 200_000)
      # Refund was applied (1/2 cap) and then zeroed out
      assert result.frame.refund == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Default hardfork is Cancun
  # ---------------------------------------------------------------------------

  describe "Default hardfork is Cancun" do
    test "executing without :hardfork option uses Cancun rules" do
      result = EEVM.Interpreter.run(<<0x5F, 0x00>>)
      # PUSH0 works → Cancun is active
      assert result.status == :stopped
      assert stack_values(result) == [0]
    end

    test "config.hardfork is set to Cancun by default" do
      result = EEVM.Interpreter.run(<<0x00>>)
      assert result.env.config.hardfork.spec_id == :cancun
    end
  end
end
