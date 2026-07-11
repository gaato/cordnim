import std/unittest

when defined(cordnimSodium):
  import std/strutils

import cordnim/interactions

suite "libsodium interaction verifier":
  test "default builds fail closed without a native verifier":
    when defined(cordnimSodium):
      check sodiumVerifierEnabled
    else:
      check not sodiumVerifierEnabled
      var publicKey: array[32, byte]
      var signature: array[64, byte]
      check not sodiumEd25519Verifier(publicKey, signature, @[byte 1])

  when defined(cordnimSodium):
    test "accepts the RFC 8032 Ed25519 test vector":
      proc decodeHex[N: static int](text: string,
                                    destination: var array[N, byte]) =
        check text.len == N * 2
        for index in 0..<N:
          destination[index] = byte(parseHexInt(
            text[index * 2 .. index * 2 + 1]
          ))

      var publicKey: array[32, byte]
      var signature: array[64, byte]
      decodeHex(
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
        publicKey
      )
      decodeHex(
        "92a009a9f0d4cab8720e820b5f642540" &
        "a2b27b5416503f8fb3762223ebdb69da" &
        "085ac1e43e15996e458f3613d0f11d8c" &
        "387b2eaeb4302aeeb00d291612bb0c00",
        signature
      )
      check sodiumEd25519Verifier(publicKey, signature, @[byte 0x72])
