defmodule EEVM.Crypto.RIPEMD160Test do
  use ExUnit.Case, async: true

  alias EEVM.Crypto.RIPEMD160

  doctest RIPEMD160

  # Test vectors from the RIPEMD-160 page of Bosselaers, Dobbertin and
  # Preneel (homes.esat.kuleuven.be/~bosselae/ripemd160.html).
  @vectors [
    {"a", "0bdc9d2d256b3ee9daae347be6f4dc835a467ffe"},
    {"message digest", "5d0689ef49d2fae572b881b123a85ffa21595f36"},
    {"abcdefghijklmnopqrstuvwxyz", "f71c27109c692c1b56bbdceb5b9d2865b3708dbc"},
    # 56 bytes: the length no longer fits, so padding spills into a second block.
    {"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
     "12a053384a9c0c88e405a06c27dcf49ada62eb2b"},
    {"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
     "b0e20b6e3116640286ed3a87a5713079b21f5189"},
    {String.duplicate("1234567890", 8), "9b752e45573d4b39f4dbd3323cab82bf63326bfb"}
  ]

  for {message, digest} <- @vectors do
    test "#{byte_size(message)}-byte vector" do
      assert unquote(message) |> RIPEMD160.hash() |> Base.encode16(case: :lower) ==
               unquote(digest)
    end
  end

  test "one million 'a' bytes" do
    assert :binary.copy("a", 1_000_000) |> RIPEMD160.hash() |> Base.encode16(case: :lower) ==
             "52783243c1697bdbe16d37f97f68f08325dc1528"
  end
end
