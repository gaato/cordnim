import std/[sequtils, strutils, unittest]

import cordnim/components

suite "component route HMAC":
  test "matches RFC 4231 HMAC-SHA-256 vector":
    let key = newSeqWith(20, byte 0x0b)
    let message = "Hi There"
    var bytes = newSeq[byte](message.len)
    for index, value in message:
      bytes[index] = byte(ord(value))
    let digest = bearsslHmacSha256(key, bytes)
    var encoded = ""
    for value in digest:
      encoded.add toHex(value, 2).toLowerAscii()
    check encoded ==
      "b0344c61d8db38535ca8afceaf0bf12b" &
      "881dc200c9833da726e9376c2e32cff7"

  test "signs and verifies a persistent route":
    let codec = RouteCodec(
      activeKeyId: 1,
      keys: @[RouteSigningKey(
        id: 1,
        material: @[byte 1, 2, 3, 4, 5, 6, 7, 8]
      )]
    ).withBearsslSigner()
    let encoded = codec.encodeRoute(9, 1, 2_000, @[byte 7])
    check codec.decodeRoute(encoded, 1_000).ok
