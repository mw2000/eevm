defmodule EEVM.MPT.TrieTest do
  use ExUnit.Case, async: true

  alias EEVM.MPT.Trie

  describe "root_hash/1" do
    test "empty trie" do
      assert Trie.root_hash([]) ==
               hex_to_bin("56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421")
    end

    test "branch-value-update vector" do
      entries = [{"abc", "123"}, {"abcd", "abcd"}, {"abc", "abc"}]

      assert Trie.root_hash(entries) ==
               hex_to_bin("7a320748f780ad9ad5b0837302075ce0eeba6c26e3d8562c67ccc0f1b273298a")
    end

    test "insert-middle-leaf vector" do
      entries = [
        {"key1aa", "0123456789012345678901234567890123456789xxx"},
        {"key1", "0123456789012345678901234567890123456789Very_Long"},
        {"key2bb", "aval3"},
        {"key2", "short"},
        {"key3cc", "aval3"},
        {"key3", "1234567890123456789012345678901"}
      ]

      assert Trie.root_hash(entries) ==
               hex_to_bin("cb65032e2f76c48b82b5c24b3db8f670ce73982869d38cd39a624f23d62a9e89")
    end

    test "emptyValues vector with deletions" do
      operations = [
        {"do", "verb"},
        {"ether", "wookiedoo"},
        {"horse", "stallion"},
        {"shaman", "horse"},
        {"doge", "coin"},
        {"ether", nil},
        {"dog", "puppy"},
        {"shaman", nil}
      ]

      assert Trie.root_hash(operations) ==
               hex_to_bin("5991bb8c6514148a29db676a14ac506cd2cd5775ace63c30a4fe457715e9ac84")
    end

    test "trieanyorder single item" do
      entries = [{"A", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]

      assert Trie.root_hash(entries) ==
               hex_to_bin("d23786fb4a010da3ce639d66d5e904a11dbc02746d1ce25029e53290cabf28ab")
    end

    test "trieanyorder dogs" do
      entries = [{"doe", "reindeer"}, {"dog", "puppy"}, {"dogglesworth", "cat"}]

      assert Trie.root_hash(entries) ==
               hex_to_bin("8aad789dff2f538bca5d8ea56e8abe10f4c7ba3a5dea95fea4cd6e7c3a1168d3")
    end

    test "trieanyorder puppy" do
      entries = [{"do", "verb"}, {"horse", "stallion"}, {"doge", "coin"}, {"dog", "puppy"}]

      assert Trie.root_hash(entries) ==
               hex_to_bin("5991bb8c6514148a29db676a14ac506cd2cd5775ace63c30a4fe457715e9ac84")
    end
  end

  describe "secure_root_hash/1" do
    test "secure trie dogs vector" do
      entries = [{"doe", "reindeer"}, {"dog", "puppy"}, {"dogglesworth", "cat"}]

      assert Trie.secure_root_hash(entries) ==
               hex_to_bin("d4cd937e4a4368d7931a9cf51686b7e10abb3dce38a39000fd7902a092b64585")
    end
  end

  defp hex_to_bin(hex) do
    normalized =
      case hex do
        "0x" <> rest -> rest
        rest -> rest
      end

    Base.decode16!(normalized, case: :lower)
  end
end
