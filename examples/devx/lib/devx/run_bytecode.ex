defmodule Devx.RunBytecode do
  @moduledoc "Task 1: run a snippet of bytecode and read the result, gas used, and return data."

  @doc """
  Adds `a` and `b` (each under 256) in EVM bytecode and returns the sum as a
  32-byte word: `PUSH1 a, PUSH1 b, ADD, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN`.
  """
  def add(a, b) do
    code = <<0x60, a, 0x60, b, 0x01, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xF3>>
    {:ok, result} = EEVM.run(code, gas: 100_000)

    %{
      status: result.status,
      sum: :binary.decode_unsigned(result.return_data),
      return_data: EEVM.hex(result.return_data),
      gas_used: result.gas_used,
      gas_left: result.gas_left
    }
  end

  @doc "Runs hex bytecode, as copied from solc or a block explorer, and returns the final stack."
  def stack(hex) do
    {:ok, result} = EEVM.run(EEVM.bytes(hex), debug: true)
    {result.status, result.stack}
  end

  @doc "Disassembles hex bytecode."
  def disassemble(hex), do: hex |> EEVM.bytes() |> EEVM.disassemble()

  @doc "Passes a hex string straight to `EEVM.run/2`, a common mistake."
  def run_hex_string(hex), do: EEVM.run(hex)
end
