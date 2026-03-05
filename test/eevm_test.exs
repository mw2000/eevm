defmodule EEVMTest do
  use ExUnit.Case
  doctest EEVM

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
