defmodule EEVM.TestSupport.BytecodeHelpers do
  @moduledoc false

  @spec build_create_program(binary(), :create, non_neg_integer()) :: binary()
  def build_create_program(init_code, :create, value) do
    init_writer =
      init_code
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.flat_map(fn {byte, offset} -> [0x60, byte, 0x60, offset, 0x53] end)

    create_part =
      [byte_size(init_code), 0x00, value]
      |> Enum.flat_map(fn item -> [0x60, item] end)

    :erlang.list_to_binary(init_writer ++ create_part ++ [0xF0, 0x00])
  end

  @spec build_create_program(binary(), :create2, non_neg_integer(), non_neg_integer()) :: binary()
  def build_create_program(init_code, :create2, value, salt) do
    init_writer =
      init_code
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.flat_map(fn {byte, offset} -> [0x60, byte, 0x60, offset, 0x53] end)

    create_part =
      [salt, byte_size(init_code), 0x00, value]
      |> Enum.flat_map(fn item -> [0x60, item] end)

    :erlang.list_to_binary(init_writer ++ create_part ++ [0xF5, 0x00])
  end
end
