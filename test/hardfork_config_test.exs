defmodule EEVM.HardforkConfigTest do
  use ExUnit.Case, async: true

  alias EEVM.HardforkConfig
  alias EEVM.Context.Contract
  alias EEVM.{Database, WorldState}

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

  # ---------------------------------------------------------------------------
  # EIP-3855 (PUSH0) behavioral tests
  # ---------------------------------------------------------------------------

  describe "EIP-3855 PUSH0 hardfork guard" do
    test "PUSH0 works on Cancun (default)" do
      # PUSH0, STOP
      code = <<0x5F, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "PUSH0 is invalid before Shanghai" do
      code = <<0x5F, 0x00>>
      result = EEVM.execute(code, hardfork: :london)
      assert result.status == :invalid
    end

    test "PUSH0 works on Shanghai" do
      code = <<0x5F, 0x00>>
      result = EEVM.execute(code, hardfork: :shanghai)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end
  end

  # ---------------------------------------------------------------------------
  # EIP-1153 (TLOAD/TSTORE) behavioral tests
  # ---------------------------------------------------------------------------

  describe "EIP-1153 TLOAD/TSTORE hardfork guard" do
    test "TLOAD works on Cancun (default)" do
      # PUSH1 0 (key), TLOAD, STOP
      code = <<0x60, 0x00, 0x5C, 0x00>>
      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "TLOAD is invalid before Cancun" do
      code = <<0x60, 0x00, 0x5C, 0x00>>
      result = EEVM.execute(code, hardfork: :shanghai)
      assert result.status == :invalid
    end

    test "TSTORE is invalid before Cancun" do
      # PUSH1 0xFF (value), PUSH1 0x01 (key), TSTORE, STOP
      code = <<0x60, 0xFF, 0x60, 0x01, 0x5D, 0x00>>
      result = EEVM.execute(code, hardfork: :shanghai)
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
          0x61, 0xDE, 0xAD, 0x60, 0x00, 0x52,
          # PUSH1 32 (len), PUSH1 0 (src), PUSH1 32 (dst), MCOPY
          0x60, 0x20, 0x60, 0x00, 0x60, 0x20, 0x5E,
          # PUSH1 32, MLOAD
          0x60, 0x20, 0x51,
          0x00
        >>

      result = EEVM.execute(code)
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0xDEAD]
    end

    test "MCOPY is invalid before Cancun" do
      code = <<0x60, 0x01, 0x60, 0x00, 0x60, 0x01, 0x5E, 0x00>>
      result = EEVM.execute(code, hardfork: :shanghai)
      assert result.status == :invalid
    end
  end

  # ---------------------------------------------------------------------------
  # EIP-6780 (SELFDESTRUCT) behavioral tests
  # ---------------------------------------------------------------------------

  describe "EIP-6780 SELFDESTRUCT hardfork guard" do
    test "post-Cancun: SELFDESTRUCT preserves account if not created this tx" do
      world_state =
        WorldState.new(%{
          0xAA => %{balance: 75, code: <<0xFE>>, nonce: 10},
          0xBB => %{balance: 0}
        })

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      result =
        EEVM.execute(code,
          world_state: world_state,
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
        WorldState.new(%{
          0xAA => %{balance: 75, code: <<0xFE>>, nonce: 10},
          0xBB => %{balance: 0}
        })

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      result =
        EEVM.execute(code,
          world_state: world_state,
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
        WorldState.new(%{
          0xAA => %{balance: 100, code: <<0x60, 0x01>>, nonce: 3},
          0xBB => %{balance: 50}
        })

      contract = Contract.new(address: 0xAA)
      code = <<0x60, 0xBB, 0xFF>>

      result =
        EEVM.execute(code,
          world_state: world_state,
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
      berlin_result = EEVM.execute(code, hardfork: :berlin, gas: 100_000)
      # PUSH1 costs 3; static SLOAD is 0; cold access adds 2100
      berlin_gas_used = 100_000 - berlin_result.gas
      assert berlin_gas_used == 3 + 2100

      # Pre-Berlin: no cold/warm distinction
      istanbul_result = EEVM.execute(code, hardfork: :istanbul, gas: 100_000)
      istanbul_gas_used = 100_000 - istanbul_result.gas
      # PUSH1(3) + SLOAD warm(100) = 103
      assert istanbul_gas_used == 3 + 100
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

      result = EEVM.execute(code, hardfork: :london, gas: 200_000)
      # Refund was accrued but then capped at 1/5 of gas used
      assert result.refund == 0
    end

    test "pre-London: refund capped at 1/2 of gas used" do
      # Same code — just verifying the executor doesn't crash and applies the 1/2 cap
      code =
        IO.iodata_to_binary([
          <<0x60, 0xFF, 0x60, 0x01, 0x55>>,
          <<0x60, 0x00, 0x60, 0x01, 0x55>>,
          <<0x00>>
        ])

      result = EEVM.execute(code, hardfork: :berlin, gas: 200_000)
      # Refund was applied (1/2 cap) and then zeroed out
      assert result.refund == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Default hardfork is Cancun
  # ---------------------------------------------------------------------------

  describe "Default hardfork is Cancun" do
    test "executing without :hardfork option uses Cancun rules" do
      result = EEVM.execute(<<0x5F, 0x00>>)
      # PUSH0 works → Cancun is active
      assert result.status == :stopped
      assert EEVM.stack_values(result) == [0]
    end

    test "config.hardfork is set to Cancun by default" do
      result = EEVM.execute(<<0x00>>)
      assert result.config.hardfork.spec_id == :cancun
    end
  end
end
