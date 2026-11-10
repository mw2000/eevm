defmodule EEVM.Crypto.KeccakTest do
  use ExUnit.Case, async: true

  alias EEVM.Crypto.Keccak

  doctest Keccak

  # ShortMsgKAT_256.txt from the Keccak team's KeccakKAT-3 package
  # (keccak.team/obsolete/KeccakKAT-3.zip): Keccak[r=1088, c=512] with the
  # original 0x01 padding, which is Ethereum's keccak256. The rate is 136
  # bytes, so the first three straddle the padding edge cases.
  @vectors [
    # 135 bytes, one byte of room: the padding is the single byte 0x81.
    {"b771d5cef5d1a41a93d15643d7181d2a2ef0a8e84d91812f20ed21f147bef732bf3a60ef4067c373" <>
       "4b85bc8cd471780f10dc9e8291b58339a677b960218f71e793f2797aea349406512829065d37bb55" <>
       "ea796fa4f56fd8896b49b2cd19b43215ad967c712b24e5032d065232e02c127409d2ed4146b9d75d" <>
       "763d52db98d949d3b0fed6a8052fbb",
     "bd6f5492582a7c1b116304de28314df9fffe95b0da11af52fe9440a717a34859"},
    # 136 bytes, exactly one block: the padding fills a second block.
    {"b32d95b0b9aad2a8816de6d06d1f86008505bd8c14124f6e9a163b5a2ade55f835d0ec3880ef5070" <>
       "0d3b25e42cc0af050ccd1be5e555b23087e04d7bf9813622780c7313a1954f8740b6ee2d3f71f768" <>
       "dd417f520482bd3a08d4f222b4ee9dbd015447b33507dd50f3ab4247c5de9a8abd62a8decea01e3b" <>
       "87c8b927f5b08beb37674c6f8e380c04",
     "e717a7769448abbe5fef8187954a88ac56ded1d22e63940ab80d029585a21921"},
    # 137 bytes, one byte into the second block.
    {"04410e31082a47584b406f051398a6abe74e4da59bb6f85e6b49e8a1f7f2ca00dfba5462c2cd2bfd" <>
       "e8b64fb21d70c083f11318b56a52d03b81cac5eec29eb31bd0078b6156786da3d6d8c33098c5c47b" <>
       "b67ac64db14165af65b44544d806dde5f487d5373c7f9792c299e9686b7e5821e7c8e2458315b996" <>
       "b5677d926dac57b3f22da873c601016a0d",
     "a95d50b50b4545f0947441df74a1e9d74622eb3baa49c1bbfc3a0cce6619c1aa"},
    # 255 bytes, 255 bytes: two blocks.
    {"3a3a819c48efde2ad914fbf00e18ab6bc4f14513ab27d0c178a188b61431e7f5623cb66b23346775" <>
       "d386b50e982c493adbbfc54b9a3cd383382336a1a0b2150a15358f336d03ae18f666c7573d55c4fd" <>
       "181c29e6ccfde63ea35f0adf5885cfc0a3d84a2b2e4dd24496db789e663170cef74798aa1bbcd457" <>
       "4ea0bba40489d764b2f83aadc66b148b4a0cd95246c127d5871c4f11418690a5ddf01246a0c80a43" <>
       "c70088b6183639dcfda4125bd113a8f49ee23ed306faac576c3fb0c1e256671d817fc2534a52f5b4" <>
       "39f72e424de376f4c565cca82307dd9ef76da5b7c4eb7e085172e328807c02d011ffbf33785378d7" <>
       "9dc266f6a5be6bb0e4a92eceebaeb1",
     "348fb774adc970a16b1105669442625e6adaa8257a89effdb5a802f161b862ea"}
  ]

  for {message, digest} <- @vectors do
    test "KAT: #{div(byte_size(message), 2)}-byte message" do
      message = Base.decode16!(unquote(message), case: :lower)
      assert message |> Keccak.hash_256() |> Base.encode16(case: :lower) == unquote(digest)
    end
  end
end
