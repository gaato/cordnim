import std/[assertions, json]

import cordnim/raw/model

type
  Permission {.pure.} = enum
    ViewChannel = 10

  DeliveryKind {.pure.} = enum
    Immediate = 1
    Deferred = 4

const deliveryNames = [
  ("immediate", DeliveryKind.Immediate),
  ("deferred", DeliveryKind.Deferred),
]

proc decodeUserId(raw: JsonNode): UserId =
  decodeId(UserId, raw)

func encodeUserId(value: UserId): JsonNode =
  value.toJson

block typedFieldPreservesOmittedNullAndValue:
  let payload = parseJson("""{
    "owner_id": "18446744073709551615",
    "nullable_id": null
  }""")
  let omitted = decodeDiscordField(
    payload, "missing_id", decodeUserId
  )
  let null = decodeDiscordField(
    payload, "nullable_id", decodeUserId
  )
  let present = decodeDiscordField(
    payload, "owner_id", decodeUserId
  )

  doAssert omitted.kind == FieldKind.Absent
  doAssert null.kind == FieldKind.NullValue
  doAssert present.kind == FieldKind.Present
  doAssert present.get.toUint64 == high(uint64)

  let encoded = newJObject()
  encoded["missing_id"] = newJString("stale")
  encodeDiscordFieldProperty(
    encoded, "missing_id", omitted, encodeUserId
  )
  encodeDiscordFieldProperty(
    encoded, "nullable_id", null, encodeUserId
  )
  encodeDiscordFieldProperty(
    encoded, "owner_id", present, encodeUserId
  )
  doAssert not encoded.hasKey("missing_id")
  doAssert encoded["nullable_id"].kind == JNull
  doAssert encoded["owner_id"].getStr == "18446744073709551615"

block patchPreservesLeaveClearAndSet:
  let encoded = parseJson("""{
    "unchanged": "stale",
    "cleared": "stale"
  }""")
  encodePatchProperty(
    encoded,
    "unchanged",
    leaveUnchanged[UserId](),
    encodeUserId,
  )
  encodePatchProperty(
    encoded,
    "cleared",
    clearValue[UserId](),
    encodeUserId,
  )
  encodePatchProperty(
    encoded,
    "updated",
    setValue(UserId.toId(42'u64)),
    encodeUserId,
  )
  doAssert not encoded.hasKey("unchanged")
  doAssert encoded["cleared"].kind == JNull
  doAssert encoded["updated"].getStr == "42"

block snowflakeBoundaryIsCanonicalAndTyped:
  let user = decodeId(UserId, newJString("123"))
  doAssert user.toUint64 == 123'u64
  doAssert user.toJson.getStr == "123"

  doAssertRaises RawModelError:
    discard decodeId(UserId, newJInt(123))
  doAssertRaises RawModelError:
    discard decodeId(UserId, newJString("-1"))

block arbitraryWidthBitsRoundTripUnknownHighBits:
  const wire = "1606938044258990275541962092341162602522202993782792835313728"
  let bits = decodeDiscordBits(DiscordBits[Permission], newJString(wire))
  doAssert bits.containsBit(200)
  doAssert bits.toJson.getStr == wire
  let decodedAgain = decodeDiscordBits(
    DiscordBits[Permission], bits.toJson
  )
  doAssert decodedAgain == bits

  doAssertRaises RawModelError:
    discard decodeDiscordBits(
      DiscordBits[Permission], newJInt(1024)
    )

block unknownIntegerEnumRoundTripsExactly:
  let unknown = decodeOpenEnum(
    DeliveryKind, int32, newJInt(9001)
  )
  doAssert not unknown.isKnown
  doAssert unknown.raw == 9001'i32
  doAssert unknown.toJson.getBiggestInt == 9001

  let known = decodeOpenEnum(
    DeliveryKind, uint8, newJInt(DeliveryKind.Deferred.ord)
  )
  doAssert known.isKnown
  doAssert known.requireKnown == DeliveryKind.Deferred
  doAssert known.toJson.getBiggestInt == 4

block stringEnumWireValuesRemainLossless:
  let known = decodeOpenEnum(
    DeliveryKind, string, newJString("deferred")
  )
  let unknown = decodeOpenEnum(
    DeliveryKind, string, newJString("future-delivery")
  )
  doAssert known.isKnown(deliveryNames)
  doAssert known.requireKnown(deliveryNames) == DeliveryKind.Deferred
  doAssert not unknown.isKnown(deliveryNames)
  doAssert unknown.raw == "future-delivery"
  doAssert unknown.toJson.getStr == "future-delivery"

  let encoded = toOpenEnum(DeliveryKind.Immediate, deliveryNames)
  doAssert encoded.raw == "immediate"
  doAssertRaises ValueError:
    discard toOpenEnum(
      DeliveryKind.Deferred,
      [("immediate", DeliveryKind.Immediate)],
    )

block invalidBoundaryInputsAreRejected:
  doAssertRaises RawModelError:
    discard decodeDiscordField[UserId](
      newJArray(), "owner_id", decodeUserId
    )
  doAssertRaises RawModelError:
    discard decodeOpenEnum(DeliveryKind, uint8, newJInt(-1))
