defmodule EEVM.ABI do
  @moduledoc """
  Encodes and decodes Solidity ABI data: calldata for a function call,
  return data, and event logs, as the
  [Solidity ABI specification](https://docs.soliditylang.org/en/latest/abi-spec.html)
  defines them.

      iex> calldata = EEVM.ABI.encode_call("transfer(address,uint256)", [0xB0B, 250])
      iex> byte_size(calldata)
      68
      iex> EEVM.ABI.decode(["bool"], <<1::256>>)
      {:ok, [true]}

  Types are Solidity type strings, such as `"uint256"`, `"address[]"`, or
  `"(uint256,bytes)[2]"` for a fixed-size array of tuples. Signatures may
  carry parameter names and spaces, as in Solidity source, and `uint` and
  `int` mean `uint256` and `int256`; selectors and event topics are always
  computed from the canonical form, so `"transfer(address to, uint amount)"`
  encodes the same calldata as `"transfer(address,uint256)"`.

  ## Values

  | ABI type | Elixir value |
  |----------|--------------|
  | `uint<N>`, `int<N>` | integer |
  | `address` | integer, as eevm represents addresses; encoding also takes anything `EEVM.address/1` takes |
  | `bool` | `true` or `false` |
  | `bytes<N>` | binary of exactly `N` bytes |
  | `bytes`, `string` | binary |
  | `T[]`, `T[k]` | list |
  | `(T1,T2,...)` | tuple |

  `fixed`, `ufixed`, and `function` types are not supported.

  ## Errors

  Following eevm's error rule, encoding raises `ArgumentError` for an
  unknown type or a value that doesn't fit its type, since both are mistakes
  in the caller's code. Decoding returns `{:error, :invalid_abi_data}` for
  data that doesn't match its types, since return data and logs come from
  contracts. Like Solidity's own decoder, decoding is strict: an integer,
  address, `bool`, or `bytes<N>` word with bits outside its type, or an
  offset or length past the end of the data, is an error rather than being
  masked or truncated. Bytes after the encoded values are ignored.

  Decoding work is capped at 16 times the size of the data, which is far
  more than any canonical encoding needs. Crafted offsets that point many
  values at the same bytes, which would make decoding take time quadratic
  in the input size, fail with `{:error, :invalid_abi_data}` instead.
  """

  import Bitwise

  @typedoc "An Elixir value for an ABI type; see the table in the module docs."
  @type value :: integer() | boolean() | binary() | [value()] | tuple()

  @typedoc "An event log, as in `result.logs`: topics are integers."
  @type log :: %{
          required(:topics) => [non_neg_integer()],
          required(:data) => binary(),
          optional(atom()) => term()
        }

  @doc """
  ABI-encodes `values` as the arguments of a function with parameter
  `types`, without a selector: the encoding of the tuple of the values.

  Raises `ArgumentError` for an unknown type, a wrong number of values, or a
  value that doesn't fit its type.

  ## Examples

      iex> EEVM.ABI.encode(["uint32", "bool"], [69, true]) |> EEVM.hex()
      "0x" <> String.pad_leading("45", 64, "0") <> String.pad_leading("1", 64, "0")

      iex> EEVM.ABI.encode(["string"], ["hi"]) |> byte_size()
      96
  """
  @spec encode([String.t()], [value()]) :: binary()
  def encode(types, values) when is_list(types) and is_list(values),
    do: types |> Enum.map(&parse_type!/1) |> encode_values(values)

  @doc """
  Builds calldata for a call to the function `signature` with `args`: its
  4-byte selector followed by the ABI-encoded arguments. Pass the result to
  `EEVM.call/4` or as a transaction's `data`.

  Raises `ArgumentError` for a malformed signature, a wrong number of
  arguments, or an argument that doesn't fit its type.

  ## Examples

      iex> calldata = EEVM.ABI.encode_call("balanceOf(address)", [0xA11CE])
      iex> EEVM.hex(calldata)
      "0x70a08231" <> String.duplicate("0", 59) <> "a11ce"

      iex> EEVM.ABI.encode_call("transfer(address to, uint amount)", [0xB0B, 1]) ==
      ...>   EEVM.ABI.encode_call("transfer(address,uint256)", [0xB0B, 1])
      true
  """
  @spec encode_call(String.t(), [value()]) :: binary()
  def encode_call(signature, args) when is_binary(signature) and is_list(args) do
    {name, params} = parse_signature!(signature)

    if Enum.any?(params, fn {_type, indexed} -> indexed end),
      do: raise(ArgumentError, "function parameters can't be indexed: #{inspect(signature)}")

    types = Enum.map(params, &elem(&1, 0))
    EEVM.selector(name <> canonical({:tuple, types})) <> encode_values(types, args)
  end

  @doc """
  Decodes ABI-encoded `data`, such as a call's `return_data`, as values of
  `types`. Returns `{:ok, values}`, one value per type.

  Returns `{:error, :invalid_abi_data}` when `data` doesn't hold valid
  values of `types`, and raises `ArgumentError` for an unknown type.

  ## Examples

      iex> EEVM.ABI.decode(["uint256"], <<1000::256>>)
      {:ok, [1000]}

      iex> data = EEVM.ABI.encode(["int8", "string", "uint16[]"], [-1, "eevm", [1, 2]])
      iex> EEVM.ABI.decode(["int8", "string", "uint16[]"], data)
      {:ok, [-1, "eevm", [1, 2]]}

      iex> EEVM.ABI.decode(["uint8"], <<256::256>>)
      {:error, :invalid_abi_data}
  """
  @spec decode([String.t()], binary()) :: {:ok, [value()]} | {:error, :invalid_abi_data}
  def decode(types, data) when is_list(types) and is_binary(data) do
    case types |> Enum.map(&parse_type!/1) |> decode_tuple(data, decode_budget(data)) do
      {:ok, values, _budget} -> {:ok, values}
      :error -> {:error, :invalid_abi_data}
    end
  end

  @doc """
  Decodes an event `log`, such as an entry of `result.logs`, as the event
  `signature`, which marks indexed parameters with `indexed` as Solidity
  does. Returns `{:ok, values}` with every parameter's value in declaration
  order.

  An indexed `uint`, `int`, `address`, `bool`, or `bytes<N>` parameter
  decodes to its value. Any other indexed parameter (`bytes`, `string`,
  arrays, tuples) decodes to its topic's 32 bytes, the Keccak-256 hash of
  its encoding, since the log doesn't hold the value itself.

  Returns `{:error, :event_mismatch}` when the log's first topic isn't the
  event's topic or its topic count doesn't match the indexed parameters (so
  you can try a log against several events), and
  `{:error, :invalid_abi_data}` when the log is that event but its data or
  topics don't decode. Anonymous events, which have no event topic, aren't
  supported.

  ## Example

      iex> log = %{
      ...>   address: 0x7070,
      ...>   topics: [EEVM.event_topic("Transfer(address,address,uint256)"), 0xA11CE, 0xB0B],
      ...>   data: <<250::256>>
      ...> }
      iex> EEVM.ABI.decode_log("Transfer(address indexed from, address indexed to, uint256 value)", log)
      {:ok, [0xA11CE, 0xB0B, 250]}
      iex> EEVM.ABI.decode_log("Approval(address indexed,address indexed,uint256)", log)
      {:error, :event_mismatch}
  """
  @spec decode_log(String.t(), log()) ::
          {:ok, [value()]} | {:error, :event_mismatch | :invalid_abi_data}
  def decode_log(signature, %{topics: topics, data: data})
      when is_binary(signature) and is_binary(data) do
    {name, params} = parse_signature!(signature)
    topic = EEVM.event_topic(name <> canonical({:tuple, Enum.map(params, &elem(&1, 0))}))
    indexed_count = Enum.count(params, fn {_type, indexed} -> indexed end)

    with [^topic | indexed_topics] when length(indexed_topics) == indexed_count <- topics,
         {:ok, data_values, _budget} <-
           decode_tuple(for({type, false} <- params, do: type), data, decode_budget(data)),
         {:ok, values} <- merge_log_values(params, indexed_topics, data_values, []) do
      {:ok, values}
    else
      :error -> {:error, :invalid_abi_data}
      _topics -> {:error, :event_mismatch}
    end
  end

  defp merge_log_values([], [], [], acc), do: {:ok, Enum.reverse(acc)}

  defp merge_log_values([{_type, false} | params], topics, [value | values], acc),
    do: merge_log_values(params, topics, values, [value | acc])

  defp merge_log_values([{type, true} | params], [topic | topics], values, acc) do
    with {:ok, value} <- decode_topic(type, topic),
         do: merge_log_values(params, topics, values, [value | acc])
  end

  # Value types are stored in their topic; any other indexed value is
  # replaced by the Keccak-256 hash of its encoding (ABI spec, "Events").
  defp decode_topic(type, topic) when is_integer(topic) and topic >= 0 and topic < 1 <<< 256 do
    if value_type?(type), do: decode_word(type, <<topic::256>>), else: {:ok, <<topic::256>>}
  end

  defp decode_topic(_type, _topic), do: :error

  defp value_type?({kind, _bits}) when kind in [:uint, :int, :bytes], do: true
  defp value_type?(type), do: type in [:address, :bool]

  # -- Encoding ---------------------------------------------------------------

  defp encode_values(types, values) when length(types) == length(values),
    do: types |> Enum.zip(values) |> encode_tuple()

  defp encode_values(types, values) do
    raise ArgumentError,
          "expected #{length(types)} values for #{canonical({:tuple, types})}, got #{length(values)}"
  end

  # Heads in order, then the tails of the dynamic values; each dynamic
  # value's head is the byte offset of its tail from the tuple's start.
  defp encode_tuple(pairs) do
    head_size = Enum.reduce(pairs, 0, fn {type, _value}, size -> size + head_size(type) end)

    {heads, tails, _offset} =
      Enum.reduce(pairs, {[], [], head_size}, fn {type, value}, {heads, tails, offset} ->
        encoded = encode_value(type, value)

        if dynamic?(type),
          do: {[heads, <<offset::256>>], [tails, encoded], offset + byte_size(encoded)},
          else: {[heads, encoded], tails, offset}
      end)

    IO.iodata_to_binary([heads, tails])
  end

  defp encode_value({:uint, bits}, value)
       when is_integer(value) and value >= 0 and value < 1 <<< bits,
       do: <<value::256>>

  defp encode_value({:int, bits}, value)
       when is_integer(value) and value >= -(1 <<< (bits - 1)) and value < 1 <<< (bits - 1),
       do: <<value::signed-256>>

  defp encode_value(:address, value), do: <<EEVM.address(value)::256>>
  defp encode_value(:bool, true), do: <<1::256>>
  defp encode_value(:bool, false), do: <<0::256>>

  defp encode_value({:bytes, size}, value) when is_binary(value) and byte_size(value) == size,
    do: pad_right(value)

  defp encode_value(type, value) when type in [:bytes, :string] and is_binary(value),
    do: <<byte_size(value)::256>> <> pad_right(value)

  defp encode_value({:array, type}, values) when is_list(values),
    do: <<length(values)::256>> <> encode_tuple(Enum.map(values, &{type, &1}))

  defp encode_value({:array, type, size}, values) when is_list(values) and length(values) == size,
    do: encode_tuple(Enum.map(values, &{type, &1}))

  defp encode_value({:tuple, types}, value)
       when is_tuple(value) and tuple_size(value) == length(types),
       do: encode_tuple(Enum.zip(types, Tuple.to_list(value)))

  defp encode_value(type, value),
    do: raise(ArgumentError, "#{inspect(value)} is not a valid #{canonical(type)}")

  defp pad_right(data), do: data <> <<0::size(rem(32 - rem(byte_size(data), 32), 32) * 8)>>

  # -- Decoding ---------------------------------------------------------------

  # Decoding charges each 32-byte word it reads, and each `bytes` or
  # `string` payload rounded up to whole words, against a budget of
  # @max_inflation times the input size. A canonical encoding reads every
  # word once, so it uses at most 1x. Many offsets that point at the same
  # tail would make decoding quadratic in the input size; they run out of
  # budget instead. ethers' Reader caps decoding the same way
  # (maxInflation).
  @max_inflation 16

  defp decode_budget(data), do: @max_inflation * byte_size(data)

  # Decodes a tuple whose encoding starts at the first byte of `data`;
  # dynamic values' offsets count from there.
  defp decode_tuple(types, data, budget) do
    types
    |> Enum.reduce_while({[], 0, budget}, fn type, {values, position, budget} ->
      case decode_at(type, data, position, budget) do
        {:ok, value, budget} -> {:cont, {[value | values], position + head_size(type), budget}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {values, _position, budget} -> {:ok, Enum.reverse(values), budget}
      :error -> :error
    end
  end

  defp decode_at(type, data, position, budget) do
    case data do
      <<_::binary-size(position), head::binary>> ->
        if dynamic?(type),
          do: decode_tail(type, data, head, budget),
          else: decode_value(type, head, budget)

      _data ->
        :error
    end
  end

  defp decode_tail(type, data, <<offset::256, _::binary>>, budget)
       when offset <= byte_size(data) and budget >= 32,
       do: decode_value(type, binary_part(data, offset, byte_size(data) - offset), budget - 32)

  defp decode_tail(_type, _data, _head, _budget), do: :error

  defp decode_value(type, <<length::256, rest::binary>>, budget)
       when type in [:bytes, :string] and length <= byte_size(rest) and
              32 + div(length + 31, 32) * 32 <= budget,
       do: {:ok, binary_part(rest, 0, length), budget - 32 - div(length + 31, 32) * 32}

  # Every element reads at least one word, so a length that the data or
  # the budget can't cover fails before any element is decoded.
  defp decode_value({:array, type}, <<length::256, rest::binary>>, budget) do
    if length * head_size(type) <= byte_size(rest) and 32 + length * 32 <= budget,
      do: decode_tuple(List.duplicate(type, length), rest, budget - 32),
      else: :error
  end

  defp decode_value({:array, type, size}, data, budget),
    do: decode_tuple(List.duplicate(type, size), data, budget)

  defp decode_value({:tuple, types}, data, budget) do
    with {:ok, values, budget} <- decode_tuple(types, data, budget),
         do: {:ok, List.to_tuple(values), budget}
  end

  defp decode_value(type, <<word::binary-size(32), _::binary>>, budget) when budget >= 32 do
    with {:ok, value} <- decode_word(type, word), do: {:ok, value, budget - 32}
  end

  defp decode_value(_type, _data, _budget), do: :error

  # A value type's word.
  defp decode_word({:uint, bits}, <<value::256>>) when value < 1 <<< bits, do: {:ok, value}

  defp decode_word({:int, bits}, <<value::signed-256>>)
       when value >= -(1 <<< (bits - 1)) and value < 1 <<< (bits - 1),
       do: {:ok, value}

  defp decode_word(:address, <<0::96, value::160>>), do: {:ok, value}
  defp decode_word(:bool, <<0::256>>), do: {:ok, false}
  defp decode_word(:bool, <<1::256>>), do: {:ok, true}

  defp decode_word({:bytes, size}, word) do
    <<value::binary-size(size), padding::binary>> = word
    if padding == <<0::size(byte_size(padding) * 8)>>, do: {:ok, value}, else: :error
  end

  defp decode_word(_type, _word), do: :error

  # -- Types ------------------------------------------------------------------

  defp dynamic?(type) when type in [:bytes, :string], do: true
  defp dynamic?({:array, _type}), do: true
  defp dynamic?({:array, type, _size}), do: dynamic?(type)
  defp dynamic?({:tuple, types}), do: Enum.any?(types, &dynamic?/1)
  defp dynamic?(_type), do: false

  # The bytes a value takes in its tuple's head: an offset for a dynamic
  # value, else its whole encoding.
  defp head_size(type) do
    cond do
      dynamic?(type) -> 32
      match?({:array, _, _}, type) -> elem(type, 2) * head_size(elem(type, 1))
      match?({:tuple, _}, type) -> type |> elem(1) |> Enum.map(&head_size/1) |> Enum.sum()
      true -> 32
    end
  end

  defp canonical({kind, bits}) when kind in [:uint, :int, :bytes], do: "#{kind}#{bits}"
  defp canonical({:array, type}), do: canonical(type) <> "[]"
  defp canonical({:array, type, size}), do: canonical(type) <> "[#{size}]"
  defp canonical({:tuple, types}), do: "(" <> Enum.map_join(types, ",", &canonical/1) <> ")"
  defp canonical(type), do: Atom.to_string(type)

  # -- Parsing ----------------------------------------------------------------

  defp parse_type!(string) when is_binary(string) do
    with {:ok, type, rest} <- parse_type(String.trim_leading(string)),
         "" <- String.trim(rest) do
      type
    else
      _error -> raise ArgumentError, "not an ABI type: #{inspect(string)}"
    end
  end

  defp parse_type!(other), do: raise(ArgumentError, "not an ABI type: #{inspect(other)}")

  # signature := name "(" [param ("," param)*] ")"; returns the name and
  # `{type, indexed?}` per parameter.
  defp parse_signature!(signature) do
    {name, rest} = signature |> String.trim_leading() |> take_identifier()

    with true <- name != "",
         {:ok, params, rest} <- parse_params(String.trim_leading(rest)),
         "" <- String.trim(rest) do
      {name, params}
    else
      _error -> raise ArgumentError, "not a function or event signature: #{inspect(signature)}"
    end
  end

  defp parse_params("(" <> rest) do
    case String.trim_leading(rest) do
      ")" <> rest -> {:ok, [], rest}
      rest -> parse_param_list(rest, [])
    end
  end

  defp parse_params(_input), do: :error

  defp parse_param_list(input, params) do
    with {:ok, param, rest} <- parse_param(input) do
      case String.trim_leading(rest) do
        "," <> rest -> parse_param_list(String.trim_leading(rest), [param | params])
        ")" <> rest -> {:ok, Enum.reverse([param | params]), rest}
        _rest -> :error
      end
    end
  end

  # param := type ["indexed"] [name]
  defp parse_param(input) do
    with {:ok, type, rest} <- parse_type(input) do
      case take_words(rest, []) do
        {[], rest} -> {:ok, {type, false}, rest}
        {["indexed"], rest} -> {:ok, {type, true}, rest}
        {["indexed", _name], rest} -> {:ok, {type, true}, rest}
        {[_name], rest} -> {:ok, {type, false}, rest}
        {_words, _rest} -> :error
      end
    end
  end

  # type := ("(" [param ("," param)*] ")" | elementary) ("[]" | "[" k "]")*
  defp parse_type("(" <> _ = input) do
    case parse_params(input) do
      {:ok, [_ | _] = params, rest} ->
        if Enum.any?(params, &elem(&1, 1)),
          do: :error,
          else: parse_suffixes({:tuple, Enum.map(params, &elem(&1, 0))}, rest)

      _empty_or_error ->
        :error
    end
  end

  defp parse_type(input) do
    {name, rest} = take_identifier(input)

    case elementary(name) do
      {:ok, type} -> parse_suffixes(type, rest)
      :error -> :error
    end
  end

  defp parse_suffixes(type, "[]" <> rest), do: parse_suffixes({:array, type}, rest)

  defp parse_suffixes(type, "[" <> <<digit, _::binary>> = input) when digit in ?1..?9 do
    "[" <> digits = input

    case Integer.parse(digits) do
      {size, "]" <> rest} -> parse_suffixes({:array, type, size}, rest)
      _other -> :error
    end
  end

  defp parse_suffixes(_type, "[" <> _rest), do: :error
  defp parse_suffixes(type, rest), do: {:ok, type, rest}

  defp elementary("address"), do: {:ok, :address}
  defp elementary("bool"), do: {:ok, :bool}
  defp elementary("string"), do: {:ok, :string}
  defp elementary("bytes"), do: {:ok, :bytes}
  defp elementary("uint"), do: {:ok, {:uint, 256}}
  defp elementary("int"), do: {:ok, {:int, 256}}
  defp elementary("uint" <> digits), do: sized(:uint, digits, 8..256//8)
  defp elementary("int" <> digits), do: sized(:int, digits, 8..256//8)
  defp elementary("bytes" <> digits), do: sized(:bytes, digits, 1..32)
  defp elementary(_name), do: :error

  defp sized(kind, digits, range) do
    case Integer.parse(digits) do
      {size, ""} ->
        if size in range and Integer.to_string(size) == digits,
          do: {:ok, {kind, size}},
          else: :error

      _other ->
        :error
    end
  end

  # Parameter names and `indexed` after a type, each preceded by whitespace.
  defp take_words(input, words) do
    trimmed = String.trim_leading(input)
    {word, rest} = take_identifier(trimmed)

    if word != "" and trimmed != input,
      do: take_words(rest, words ++ [word]),
      else: {words, input}
  end

  defp take_identifier(input), do: take_identifier(input, 0)

  defp take_identifier(input, length) do
    case input do
      <<_::binary-size(length), char, _::binary>>
      when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?_, ?$] ->
        take_identifier(input, length + 1)

      <<identifier::binary-size(length), rest::binary>> ->
        {identifier, rest}
    end
  end
end
