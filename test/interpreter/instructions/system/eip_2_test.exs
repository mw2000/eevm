defmodule EEVM.Interpreter.Instructions.System.EIP2Test do
  use ExUnit.Case, async: true
  import EEVM.TestSupport.MachineHelpers

  alias EEVM.{Config, Database}

  # Stores the initcode PUSH1 100 PUSH1 0 RETURN (100 bytes of runtime code, a
  # 20,000-gas deposit) at memory 27..31, then CREATE(0, 27, 5) and STOP.
  @create <<0x64, 0x60, 0x64, 0x60, 0x00, 0xF3, 0x60, 0x00, 0x52, 0x60, 0x05, 0x60, 0x1B, 0x60,
            0x00, 0xF0, 0x00>>

  # Before EIP-150 CREATE forwards all remaining gas: 40,000 - 21 for the
  # setup (five pushes, MSTORE, one word of memory) - 32,000 for CREATE leaves
  # 7,979, too little for the deposit.
  @gas 40_000

  test "before Homestead, CREATE that can't pay the code deposit succeeds with empty code" do
    # EEST frontier/create/test_create_deposit_oog; execution-specs Frontier
    # process_create_message clears the output instead of failing.
    result = run_code(@create, gas: @gas, config: Config.new(:frontier))

    assert [address] = stack_values(result)
    assert address != 0
    assert Database.account_exists?(result.db, address)
    assert Database.get_code(result.db, address) == <<>>
    # The child's unspent gas comes back: 7,979 less the initcode's 18 (6 for
    # its opcodes, 12 for 4 words of memory). No deposit is charged.
    assert result.frame.gas == 7_979 - 18
  end

  test "from Homestead (EIP-2), CREATE that can't pay the code deposit fails" do
    result = run_code(@create, gas: @gas, config: Config.new(:homestead))

    assert stack_values(result) == [0]
    assert result.frame.gas == 0
  end
end
