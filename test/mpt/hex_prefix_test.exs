defmodule EEVM.MPT.HexPrefixTest do
  use ExUnit.Case, async: true

  alias EEVM.MPT.HexPrefix

  describe "encode/2" do
    test "matches Ethereum compact encoding vectors" do
      assert HexPrefix.encode([1, 2, 3, 4, 5], false) == <<0x11, 0x23, 0x45>>
      assert HexPrefix.encode([0, 1, 2, 3, 4, 5], false) == <<0x00, 0x01, 0x23, 0x45>>
      assert HexPrefix.encode([0, 15, 1, 12, 11, 8], true) == <<0x20, 0x0F, 0x1C, 0xB8>>
      assert HexPrefix.encode([15, 1, 12, 11, 8], true) == <<0x3F, 0x1C, 0xB8>>
    end
  end

  describe "decode/1" do
    test "roundtrips known vectors" do
      cases = [
        {[1, 2, 3, 4, 5], false},
        {[0, 1, 2, 3, 4, 5], false},
        {[0, 15, 1, 12, 11, 8], true},
        {[15, 1, 12, 11, 8], true},
        {[], false},
        {[], true}
      ]

      Enum.each(cases, fn {nibbles, is_leaf} ->
        encoded = HexPrefix.encode(nibbles, is_leaf)
        assert HexPrefix.decode(encoded) == {nibbles, is_leaf}
      end)
    end
  end
end
