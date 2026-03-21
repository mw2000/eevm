defmodule EEVM.ConfigTest do
  use ExUnit.Case, async: true

  alias EEVM.{Config, HardforkConfig}

  test "register_precompile stores custom module at address" do
    config = Config.new() |> Config.register_precompile(0x100, EEVM.Precompiles.Identity)

    assert config.precompiles[0x100] == EEVM.Precompiles.Identity
  end

  test "Config.new/0 defaults to Cancun hardfork" do
    config = Config.new()
    assert config.hardfork.spec_id == :cancun
  end

  test "Config.new/1 accepts a specific hardfork" do
    config = Config.new(:berlin)
    assert config.hardfork.spec_id == :berlin
  end

  test "Config.new hardfork is a proper HardforkConfig struct" do
    config = Config.new(:london)
    assert %HardforkConfig{spec_id: :london} = config.hardfork
  end
end
