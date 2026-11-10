defmodule EEVM.Crypto.SHA256Test do
  use ExUnit.Case, async: true

  alias EEVM.Crypto.SHA256

  doctest SHA256

  defp hex(message), do: message |> SHA256.hash() |> Base.encode16(case: :lower)

  # FIPS 180-2 Appendix B examples.
  test "B.1: one-block message" do
    assert hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end

  test "B.2: 56-byte message whose padding spills into a second block" do
    message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    assert byte_size(message) == 56
    assert hex(message) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  end

  test "B.3: one million 'a' bytes" do
    assert hex(:binary.copy("a", 1_000_000)) ==
             "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
  end
end
