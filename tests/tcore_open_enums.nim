import std/[assertions, hashes, options, tables]

import cordnim/core/open_enums

type
  DeliveryKind {.pure.} = enum
    Immediate = 1
    Deferred = 4

  NegativeKind {.pure.} = enum
    BelowZero = -1

  LargeKind {.pure.} = enum
    AboveByte = 300

block knownAndUnknownValues:
  let known = initOpenEnum[DeliveryKind](4'i32)
  let unknown = initOpenEnum[DeliveryKind](3'i32)

  doAssert known.isKnown
  doAssert known.knownValue == some(DeliveryKind.Deferred)
  doAssert known.requireKnown == DeliveryKind.Deferred
  doAssert not unknown.isKnown
  doAssert unknown.knownValue.isNone
  doAssert unknown.raw == 3
  doAssert $unknown == "3"

  doAssertRaises ValueError:
    discard unknown.requireKnown

block knownConversion:
  let value = toOpenEnum(DeliveryKind.Immediate, uint8)
  doAssert value.raw == 1'u8
  doAssert value.knownValue == some(DeliveryKind.Immediate)

  doAssertRaises ValueError:
    discard toOpenEnum(NegativeKind.BelowZero, uint8)
  doAssertRaises ValueError:
    discard toOpenEnum(LargeKind.AboveByte, uint8)

block nonIntegerRawRoundTrip:
  let value = initOpenEnum[DeliveryKind]("future")
  doAssert value.toRaw == "future"
  doAssert $value == "future"

block equalityAndHash:
  let first = initOpenEnum[DeliveryKind](99'i16)
  let second = initOpenEnum[DeliveryKind](99'i16)
  doAssert first == second
  doAssert hash(first) == hash(second)

  var values = initTable[OpenEnum[DeliveryKind, int16], string]()
  values[first] = "future"
  doAssert values[second] == "future"
