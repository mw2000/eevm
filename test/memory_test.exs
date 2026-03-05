defmodule EEVM.MemoryTest do
  use ExUnit.Case, async: true

  alias EEVM.Memory

  describe "Memory" do
    test "store and load word" do
      mem = Memory.new()
      mem = Memory.store(mem, 0, 0xFF)

      {value, _mem} = Memory.load(mem, 0)
      assert value == 0xFF
    end

    test "store byte" do
      mem = Memory.new()
      mem = Memory.store_byte(mem, 0, 0xAB)
      mem = Memory.store_byte(mem, 1, 0xCD)

      {value, _mem} = Memory.load(mem, 0)
      # First two bytes are 0xAB, 0xCD, rest are zeros
      assert value == 0xABCD000000000000000000000000000000000000000000000000000000000000
    end

    test "memory expands in 32-byte chunks" do
      mem = Memory.new()
      assert Memory.size(mem) == 0

      mem = Memory.store_byte(mem, 0, 1)
      assert Memory.size(mem) == 32

      mem = Memory.store_byte(mem, 33, 1)
      assert Memory.size(mem) == 64
    end

    test "uninitialized memory reads as zero" do
      mem = Memory.new()
      {value, _mem} = Memory.load(mem, 0)
      assert value == 0
    end
  end
end
