import std/[assertions, hashes, strutils, tables]

import cordnim/core/bits

type
  Permission {.pure.} = enum
    CreateInstantInvite = 0
    ViewChannel = 10
    SendMessages = 11
    FutureKnownPermission = 130

block zeroAndUint64Boundaries:
  let zero = initDiscordBits[Permission]()
  doAssert zero.isZero
  doAssert zero.toDecimal == "0"
  doAssert zero.toLimbs.len == 0
  doAssert zero.toUint64 == 0'u64

  let maximum = parseDiscordBits[Permission]("18446744073709551615")
  doAssert maximum.toUint64 == high(uint64)
  doAssert maximum.toDecimal == "18446744073709551615"

block arbitraryWidthDecimalRoundTrip:
  const values = [
    "18446744073709551616",
    "340282366920938463463374607431768211455",
    "115792089237316195423570985008687907853269984665640564039457" &
      "584007913129639935"
  ]
  for text in values:
    let bits = parseDiscordBits[Permission](text)
    doAssert bits.toDecimal == text
    doAssert $bits == text

  let normalized = parseDiscordBits[Permission]("00000000123")
  doAssert normalized.toDecimal == "123"

block limbCanonicalization:
  let bits = initDiscordBits[Permission]([3'u64, 0'u64, 0'u64])
  doAssert bits.toLimbs == @[3'u64]
  doAssert bits == initDiscordBits[Permission](3'u64)

  var copiedLimbs = bits.toLimbs
  copiedLimbs[0] = 99'u64
  doAssert bits.toLimbs == @[3'u64]

block deterministicLimbRoundTrips:
  # Fixed xorshift input exercises multi-limb conversions without introducing
  # nondeterminism or depending on the standard random generator's version.
  var seed = 0x4d59_5df4_d0f3_3173'u64
  for limbCount in 1..12:
    var limbs: seq[uint64]
    for index in 0..<limbCount:
      seed = seed xor (seed shl 13)
      seed = seed xor (seed shr 7)
      seed = seed xor (seed shl 17)
      limbs.add seed xor uint64(index)
    limbs[^1] = limbs[^1] or 1'u64

    let original = initDiscordBits[Permission](limbs)
    let decoded = parseDiscordBits[Permission](original.toDecimal)
    doAssert decoded == original

block knownAndUnknownBits:
  var bits = initDiscordBits[Permission]([
    Permission.ViewChannel,
    Permission.FutureKnownPermission
  ])
  bits.incl(Permission.SendMessages)
  bits.inclBit(200)

  doAssert bits.contains(Permission.ViewChannel)
  doAssert bits.contains(Permission.SendMessages)
  doAssert bits.contains(Permission.FutureKnownPermission)
  doAssert bits.containsBit(200)
  doAssert not bits.contains(Permission.CreateInstantInvite)

  let unknown = bits.unknownBits
  doAssert unknown.containsBit(200)
  doAssert not unknown.contains(Permission.ViewChannel)

  let known = bits.knownBits
  doAssert known.contains(Permission.ViewChannel)
  doAssert known.contains(Permission.SendMessages)
  doAssert known.contains(Permission.FutureKnownPermission)
  doAssert not known.containsBit(200)

  bits.excl(Permission.SendMessages)
  bits.exclBit(200)
  doAssert not bits.contains(Permission.SendMessages)
  doAssert not bits.containsBit(200)

block exactAndTruncatingUint64Conversion:
  let bits = initDiscordBits[Permission]([5'u64, 1'u64])
  doAssert bits.lowUint64 == 5'u64
  doAssertRaises ValueError:
    discard bits.toUint64

block invalidDecimalInput:
  for invalid in ["", "-1", "+1", " 1", "1 ", "1_0", "abc"]:
    doAssertRaises ValueError:
      discard parseDiscordBits[Permission](invalid)

  doAssertRaises ValueError:
    discard parseDiscordBits[Permission]("12345", maxDigits = 4)

  let maximumInput = repeat('9', defaultMaxBitsDigits)
  doAssert parseDiscordBits[Permission](maximumInput).toDecimal ==
    maximumInput
  doAssertRaises ValueError:
    discard parseDiscordBits[Permission](maximumInput & "9")

block equalityAndHash:
  let first = parseDiscordBits[Permission](
    "340282366920938463463374607431768211455")
  let second = initDiscordBits[Permission]([
    high(uint64),
    high(uint64)
  ])
  doAssert first == second
  doAssert hash(first) == hash(second)

  var values = initTable[DiscordBits[Permission], string]()
  values[first] = "all 128 bits"
  doAssert values[second] == "all 128 bits"
