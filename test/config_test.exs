defmodule EEVM.ConfigTest do
  use ExUnit.Case, async: true

  alias EEVM.Config

  test "register_precompile stores custom module at address" do
    config = Config.new() |> Config.register_precompile(0x100, EEVM.Precompiles.Identity)

    assert config.precompiles[0x100] == EEVM.Precompiles.Identity
  end
end
