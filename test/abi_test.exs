defmodule EEVM.ABITest do
  use ExUnit.Case, async: true

  alias EEVM.ABI

  doctest EEVM.ABI

  # A word per element: integers as uint256, binaries left-aligned and
  # right-padded, as the ABI spec lays out its examples.
  defp words(items) do
    for item <- items, into: <<>> do
      if is_integer(item),
        do: <<item::256>>,
        else: item <> <<0::size((32 - byte_size(item)) * 8)>>
    end
  end

  describe "the Solidity ABI spec's worked examples" do
    # https://docs.soliditylang.org/en/latest/abi-spec.html#examples and
    # #use-of-dynamic-types; every expected word is copied from the spec.
    test "baz(uint32,bool) with 69 and true, and its bool return value" do
      assert ABI.encode_call("baz(uint32,bool)", [69, true]) ==
               <<0xCDCD77C0::32>> <> words([0x45, 1])

      assert ABI.decode(["bool"], words([0])) == {:ok, [false]}
    end

    test ~s{bar(bytes3[2]) with ["abc", "def"]} do
      calldata = <<0xFCE353F6::32>> <> words(["abc", "def"])

      assert ABI.encode_call("bar(bytes3[2])", [["abc", "def"]]) == calldata
      assert ABI.decode(["bytes3[2]"], binary_part(calldata, 4, 64)) == {:ok, [["abc", "def"]]}
    end

    test ~s{sam(bytes,bool,uint[]) with "dave", true and [1,2,3]; uint is uint256} do
      args = words([0x60, 1, 0xA0, 4, "dave", 3, 1, 2, 3])

      assert ABI.encode_call("sam(bytes,bool,uint[])", ["dave", true, [1, 2, 3]]) ==
               <<0xA5643BF2::32>> <> args

      assert ABI.decode(["bytes", "bool", "uint256[]"], args) == {:ok, ["dave", true, [1, 2, 3]]}
    end

    test "f(uint256,uint32[],bytes10,bytes)" do
      values = [0x123, [0x456, 0x789], "1234567890", "Hello, world!"]
      args = words([0x123, 0x80, "1234567890", 0xE0, 2, 0x456, 0x789, 0x0D, "Hello, world!"])

      assert ABI.encode_call("f(uint256,uint32[],bytes10,bytes)", values) ==
               <<0x8BE65246::32>> <> args

      assert ABI.decode(["uint256", "uint32[]", "bytes10", "bytes"], args) == {:ok, values}
    end

    test "g(uint256[][],string[]), nested dynamic arrays" do
      values = [[[1, 2], [3]], ["one", "two", "three"]]

      args =
        words([
          0x40,
          0x140,
          2,
          0x40,
          0xA0,
          2,
          1,
          2,
          1,
          3,
          3,
          0x60,
          0xA0,
          0xE0,
          3,
          "one",
          3,
          "two",
          5,
          "three"
        ])

      assert ABI.encode_call("g(uint256[][],string[])", values) == <<0x2289B18C::32>> <> args
      assert ABI.decode(["uint256[][]", "string[]"], args) == {:ok, values}
    end
  end

  describe "integers" do
    # ABI spec, int<M>: big-endian two's complement, left-padded with 0xff
    # bytes when negative.
    test "signed values encode as two's complement at both ends of their range" do
      assert ABI.encode(["int8"], [-1]) == :binary.copy(<<0xFF>>, 32)
      assert ABI.encode(["int8"], [-128]) == :binary.copy(<<0xFF>>, 31) <> <<0x80>>
      assert ABI.encode(["int8"], [127]) == <<127::256>>
      assert ABI.encode(["int256"], [-(2 ** 255)]) == <<0x80, 0::248>>

      for {type, value} <- [
            {"int8", -128},
            {"int8", 127},
            {"int256", -(2 ** 255)},
            {"int256", 2 ** 255 - 1}
          ] do
        assert ABI.decode([type], ABI.encode([type], [value])) == {:ok, [value]}
      end
    end

    test "unsigned values cover 0 through 2^N - 1" do
      assert ABI.encode(["uint256"], [2 ** 256 - 1]) == :binary.copy(<<0xFF>>, 32)
      assert ABI.decode(["uint256"], :binary.copy(<<0xFF>>, 32)) == {:ok, [2 ** 256 - 1]}
      assert ABI.decode(["uint8"], <<255::256>>) == {:ok, [255]}
    end

    test "encoding a value outside its type raises" do
      for {type, value} <- [
            {"uint8", 256},
            {"uint256", -1},
            {"int8", 128},
            {"int8", -129},
            {"uint256", 2 ** 256}
          ] do
        assert_raise ArgumentError, ~r/is not a valid #{type}/, fn ->
          ABI.encode([type], [value])
        end
      end
    end

    # Solidity's decoder reverts on these words instead of masking them.
    test "decoding a word with bits outside its type is invalid" do
      assert ABI.decode(["uint8"], <<256::256>>) == {:error, :invalid_abi_data}
      assert ABI.decode(["int8"], <<128::256>>) == {:error, :invalid_abi_data}
      assert ABI.decode(["int8"], <<-129::signed-256>>) == {:error, :invalid_abi_data}
      assert ABI.decode(["bool"], <<2::256>>) == {:error, :invalid_abi_data}
      assert ABI.decode(["address"], <<1::96, 0xB0B::160>>) == {:error, :invalid_abi_data}
      assert ABI.decode(["bytes3"], words(["abcd"])) == {:error, :invalid_abi_data}
    end
  end

  describe "dynamic and composite values" do
    test "empty arrays, bytes and strings are a zero length" do
      for {type, value} <- [{"uint256[]", []}, {"bytes", ""}, {"string", ""}] do
        assert ABI.encode([type], [value]) == words([0x20, 0])
        assert ABI.decode([type], words([0x20, 0])) == {:ok, [value]}
      end
    end

    test "an array of tuples with dynamic members offsets each tuple from the array's elements" do
      # [(1, "a"), (2, "")]: the array's tail is its length, then one offset
      # per tuple counted from the first offset, then each tuple's own head
      # and tail.
      encoded = words([0x20, 2, 0x40, 0xC0, 1, 0x40, 1, "a", 2, 0x40, 0])

      assert ABI.encode(["(uint256,string)[]"], [[{1, "a"}, {2, ""}]]) == encoded
      assert ABI.decode(["(uint256,string)[]"], encoded) == {:ok, [[{1, "a"}, {2, ""}]]}
    end

    test "a static tuple and a fixed array of static values are encoded in place" do
      assert ABI.encode(["(address,bool)", "uint8"], [{0xB0B, true}, 7]) == words([0xB0B, 1, 7])

      assert ABI.decode(["(address,bool)", "uint8"], words([0xB0B, 1, 7])) ==
               {:ok, [{0xB0B, true}, 7]}
    end

    test "addresses encode from any form EEVM.address/1 takes" do
      hex = "0x0000000000000000000000000000000000000b0b"
      assert ABI.encode(["address"], [hex]) == ABI.encode(["address"], [0xB0B])
      assert ABI.encode(["address"], [<<0xB0B::160>>]) == words([0xB0B])
    end

    test "values of the wrong shape raise" do
      assert_raise ArgumentError, ~r/is not a valid bytes3/, fn ->
        ABI.encode(["bytes3"], ["ab"])
      end

      assert_raise ArgumentError, ~r/is not a valid uint8\[2\]/, fn ->
        ABI.encode(["uint8[2]"], [[1]])
      end

      assert_raise ArgumentError, ~r/is not a valid \(uint8,bool\)/, fn ->
        ABI.encode(["(uint8,bool)"], [[1, true]])
      end

      assert_raise ArgumentError, ~r/expected 2 values/, fn ->
        ABI.encode(["uint8", "bool"], [1])
      end
    end
  end

  describe "decoding untrusted data" do
    test "an offset or length past the end of the data is invalid" do
      assert ABI.decode(["bytes"], words([0x40, 0])) == {:error, :invalid_abi_data}
      assert ABI.decode(["bytes"], words([0x20, 33, "x"])) == {:error, :invalid_abi_data}
      assert ABI.decode(["uint256", "uint256"], words([1])) == {:error, :invalid_abi_data}
      assert ABI.decode(["uint256"], <<>>) == {:error, :invalid_abi_data}
    end

    test "an array length larger than the data can hold is rejected without decoding it" do
      assert ABI.decode(["uint256[]"], words([0x20, 2 ** 255])) == {:error, :invalid_abi_data}
      assert ABI.decode(["string[]"], words([0x20, 2, 0x40])) == {:error, :invalid_abi_data}
    end

    test "bytes after the encoded values are ignored" do
      assert ABI.decode(["uint8"], words([5, 6])) == {:ok, [5]}
    end
  end

  describe "decode_log/2" do
    @transfer "Transfer(address indexed from, address indexed to, uint256 value)"

    test "an indexed string decodes to its topic, the Keccak-256 hash of its bytes" do
      # ABI spec, "Encoding of Indexed Event Parameters": a string topic is
      # the hash of the string's contents, without length or padding.
      <<hash::256>> = EEVM.keccak256("hello")
      topics = [EEVM.event_topic("Named(string,uint8)"), hash]

      assert ABI.decode_log("Named(string indexed, uint8)", %{topics: topics, data: words([9])}) ==
               {:ok, [<<hash::256>>, 9]}
    end

    test "a log of another event, or with the wrong number of topics, is a mismatch" do
      topic = EEVM.event_topic("Transfer(address,address,uint256)")
      data = words([250])

      assert ABI.decode_log(@transfer, %{topics: [topic, 0xA11CE, 0xB0B], data: data}) ==
               {:ok, [0xA11CE, 0xB0B, 250]}

      # ERC-721's Transfer has the same canonical signature but indexes all
      # three parameters.
      assert ABI.decode_log(@transfer, %{topics: [topic, 0xA11CE, 0xB0B, 250], data: <<>>}) ==
               {:error, :event_mismatch}

      assert ABI.decode_log(@transfer, %{topics: [], data: data}) == {:error, :event_mismatch}
    end

    test "a matching log whose topics or data don't decode is invalid" do
      topic = EEVM.event_topic("Transfer(address,address,uint256)")

      assert ABI.decode_log(@transfer, %{topics: [topic, 2 ** 160, 0xB0B], data: words([1])}) ==
               {:error, :invalid_abi_data}

      assert ABI.decode_log(@transfer, %{topics: [topic, 0xA11CE, 0xB0B], data: <<>>}) ==
               {:error, :invalid_abi_data}
    end
  end

  describe "signatures and types" do
    test "names, spaces and the uint/int aliases don't change the selector" do
      canonical = ABI.encode_call("swap((uint256,int256)[],bytes32)", [[{1, -1}], <<0::256>>])

      assert ABI.encode_call(" swap ( (uint a, int b)[] pairs , bytes32 salt ) ", [
               [{1, -1}],
               <<0::256>>
             ]) ==
               canonical
    end

    test "malformed signatures and unknown types raise" do
      for signature <- [
            "transfer(address",
            "transfer",
            "(uint256)",
            "f(uint7)",
            "f(bytes33)",
            "f(uint08)",
            "f(uint256[0])",
            "f(())",
            "f(uint256 indexed)",
            "f(uint256) x",
            "f(fixed128x18)"
          ] do
        assert_raise ArgumentError, ~r/not a function or event signature|can't be indexed/, fn ->
          ABI.encode_call(signature, [0])
        end
      end

      assert_raise ArgumentError, ~r/not an ABI type: "function"/, fn ->
        ABI.decode(["function"], <<>>)
      end

      assert_raise ArgumentError, ~r/not an ABI type/, fn -> ABI.encode(["uint256[]x"], [[]]) end
    end
  end
end
