## Focused tests for the shared semantic-model decode helpers.

import std/[json, options]

import cordnim/models/common

block ensureObjectRejectsNonObjects:
  doAssert ensureObject(%*{"a": 1}, "ctx").kind == JObject
  doAssertRaises DecodeError:
    discard ensureObject(%*[1, 2], "ctx")
  doAssertRaises DecodeError:
    discard ensureObject(newJNull(), "ctx")

block requiredFieldPresenceAndNull:
  let obj = %*{"present": 5, "explicitNull": newJNull()}
  doAssert requireField(obj, "present", "owner").getInt == 5
  doAssertRaises DecodeError:
    discard requireField(obj, "explicitNull", "owner")
  doAssertRaises DecodeError:
    discard requireField(obj, "absent", "owner")

block requiredNullableDistinguishesNullFromAbsent:
  let obj = %*{"present": 5, "explicitNull": newJNull()}
  # A present value is returned; an explicit null collapses to none.
  doAssert requireNullable(obj, "present", "owner").get.getInt == 5
  doAssert requireNullable(obj, "explicitNull", "owner").isNone
  # Absence is still rejected, unlike optionalField.
  doAssertRaises DecodeError:
    discard requireNullable(obj, "absent", "owner")

block requiredNonNullPresenceHelper:
  let obj = %*{"num": 1, "str": "x", "nulled": newJNull()}
  # requireNonNull enforces present + non-null, with JSON-type validation.
  requireNonNull(obj, "num", "owner", {JInt})
  requireNonNull(obj, "str", "owner", {JString})
  requireNonNull(obj, "num", "owner") # no kind set: any non-null value passes
  doAssertRaises DecodeError: # an explicit null is rejected, unlike a bare key
    requireNonNull(obj, "nulled", "owner")
  doAssertRaises DecodeError: # absence is rejected
    requireNonNull(obj, "absent", "owner")
  doAssertRaises DecodeError: # the wrong JSON type is rejected
    requireNonNull(obj, "num", "owner", {JString})
  requireNonNullKeys(obj, "owner", ["num", "str"])
  doAssertRaises DecodeError:
    requireNonNullKeys(obj, "owner", ["num", "nulled"])

block requiredNullablePresenceHelper:
  let obj = %*{"num": 1, "nulled": newJNull()}
  # requireNullablePresent enforces presence but permits an explicit null.
  requireNullablePresent(obj, "num", "owner", {JInt})
  requireNullablePresent(obj, "nulled", "owner", {JInt}) # null is accepted
  doAssertRaises DecodeError: # absence is still rejected
    requireNullablePresent(obj, "absent", "owner")
  doAssertRaises DecodeError: # a non-null value of the wrong type is rejected
    requireNullablePresent(obj, "num", "owner", {JString})
  requireNullablePresentKeys(obj, "owner", ["num", "nulled"])
  doAssertRaises DecodeError:
    requireNullablePresentKeys(obj, "owner", ["num", "absent"])

block optionalNonNullVersusNullable:
  let obj = %*{"val": "x", "nulled": newJNull()}
  # optionalField collapses null and absence to none (optional nullable).
  doAssert optionalField(obj, "nulled").isNone
  doAssert optionalField(obj, "absent").isNone
  # optionalNonNullField maps absence to none but rejects an explicit null.
  doAssert optionalNonNullField(obj, "absent", "owner").isNone
  doAssert optionalNonNullField(obj, "val", "owner").isSome
  doAssertRaises DecodeError:
    discard optionalNonNullField(obj, "nulled", "owner")
  # boolOr defaults on absence but rejects an explicit null.
  doAssert not boolOr(%*{}, "flag", false, "owner")
  doAssert boolOr(%*{"flag": true}, "flag", false, "owner")
  doAssertRaises DecodeError:
    discard boolOr(%*{"flag": newJNull()}, "flag", false, "owner")
  # optNonNullBool: absence -> none, value -> some, null -> reject.
  doAssert optNonNullBool(%*{}, "flag", "owner").isNone
  doAssert optNonNullBool(%*{"flag": true}, "flag", "owner") == some(true)
  doAssertRaises DecodeError:
    discard optNonNullBool(%*{"flag": newJNull()}, "flag", "owner")

block optNonNullTypedHelpers:
  let obj = %*{"str": "x", "num": 7, "id": "123456789012345678",
    "arr": [1, 2], "obj": {"k": 1}, "nulled": newJNull()}
  # Present values decode; absence yields none.
  doAssert optNonNullString(obj, "str", "owner") == some("x")
  doAssert optNonNullString(obj, "absent", "owner").isNone
  doAssert optNonNullInt(obj, "num", "owner") == some(7'i64)
  doAssert optNonNullInt(obj, "absent", "owner").isNone
  doAssert optNonNullId(UserId, obj, "id", "owner").get.toUint64 ==
    123456789012345678'u64
  doAssert optNonNullId(UserId, obj, "absent", "owner").isNone
  doAssert optNonNullArray(obj, "arr", "owner").get.len == 2
  doAssert optNonNullArray(obj, "absent", "owner").isNone
  doAssert optNonNullObject(obj, "obj", "owner").isSome
  doAssert optNonNullObject(obj, "absent", "owner").isNone
  # An explicit null is rejected for every optional non-null helper.
  for name in ["str", "num", "id", "arr", "obj"]:
    var nulled = %*{}
    nulled[name] = newJNull()
    doAssertRaises DecodeError:
      discard optNonNullString(nulled, name, "owner")
  doAssertRaises DecodeError:
    discard optNonNullInt(obj, "nulled", "owner")
  doAssertRaises DecodeError:
    discard optNonNullId(UserId, obj, "nulled", "owner")
  doAssertRaises DecodeError:
    discard optNonNullArray(obj, "nulled", "owner")
  doAssertRaises DecodeError:
    discard optNonNullObject(obj, "nulled", "owner")
  # A wrong JSON type is rejected too (an object where an array is expected).
  doAssertRaises DecodeError:
    discard optNonNullArray(obj, "obj", "owner")
  doAssertRaises DecodeError:
    discard optNonNullObject(obj, "arr", "owner")

block reqNullableIntHelper:
  let obj = %*{"num": 5, "nulled": newJNull()}
  doAssert reqNullableInt(obj, "num", "owner") == some(5'i64)
  doAssert reqNullableInt(obj, "nulled", "owner").isNone
  doAssertRaises DecodeError: # absence is rejected
    discard reqNullableInt(obj, "absent", "owner")

block expectOptionalNullableTypeCheck:
  let obj = %*{"obj": {"k": 1}, "nulled": newJNull(), "wrong": "x"}
  # Absence and an explicit null are both accepted without error.
  expectOptionalNullable(obj, "absent", "owner", {JObject})
  expectOptionalNullable(obj, "nulled", "owner", {JObject})
  expectOptionalNullable(obj, "obj", "owner", {JObject})
  # A present non-null value of the wrong type is rejected.
  doAssertRaises DecodeError:
    expectOptionalNullable(obj, "wrong", "owner", {JObject})

block reqNullableTypedHelpers:
  let obj = %*{"name": "hi", "nulled": newJNull(),
    "id": "123456789012345678"}
  doAssert reqNullableString(obj, "name", "owner") == some("hi")
  doAssert reqNullableString(obj, "nulled", "owner").isNone
  doAssert reqNullableId(UserId, obj, "id", "owner").get.toUint64 ==
    123456789012345678'u64
  doAssertRaises DecodeError:
    discard reqNullableString(obj, "absent", "owner")

block threeStateFieldDistinguishesNullAndAbsent:
  let obj = %*{"nulled": newJNull(), "valued": "x"}
  doAssert fieldState(obj, "absent").isAbsent
  doAssert fieldState(obj, "nulled").isNull
  doAssert fieldState(obj, "valued").isPresent
  # optionalField collapses null and absent into none.
  doAssert optionalField(obj, "nulled").isNone
  doAssert optionalField(obj, "absent").isNone
  doAssert optionalField(obj, "valued").isSome

block typedGettersRejectWrongTypes:
  doAssert asString(%"hello", "ctx") == "hello"
  doAssert asInt(%42, "ctx") == 42'i64
  doAssert asBool(%true, "ctx")
  doAssertRaises DecodeError:
    discard asString(%5, "ctx")
  doAssertRaises DecodeError:
    discard asInt(%"5", "ctx")
  doAssertRaises DecodeError:
    discard asBool(%1, "ctx")

block snowflakeDecoding:
  let id = decodeId(UserId, %"123456789012345678", "user.id")
  doAssert id.toUint64 == 123456789012345678'u64
  doAssertRaises DecodeError:
    discard decodeId(UserId, %123, "user.id") # integer, not string
  doAssertRaises DecodeError:
    discard decodeId(UserId, %"12x", "user.id") # malformed snowflake

block timestampPreservesWireText:
  let stamp = decodeTimestamp(%"2026-07-12T09:30:00.000000+00:00", "ts")
  doAssert stamp.iso8601 == "2026-07-12T09:30:00.000000+00:00"
  doAssert $stamp == "2026-07-12T09:30:00.000000+00:00"
  # A Z zone and a fractionless form are both accepted, verbatim.
  doAssert decodeTimestamp(%"2026-07-12T09:30:00Z", "ts").iso8601 ==
    "2026-07-12T09:30:00Z"
  doAssertRaises DecodeError:
    discard decodeTimestamp(%123, "ts")
  doAssertRaises DecodeError:
    discard decodeTimestamp(%"", "ts")

block rfc3339RejectsMalformedTimestamps:
  # A west offset and a lowercase form are both accepted, verbatim.
  doAssert isRfc3339("2026-07-12T09:30:00-05:30")
  doAssert isRfc3339("2026-07-12t09:30:00z")
  # Each of these violates a component range or the grammar.
  doAssert not isRfc3339("2026-13-12T09:30:00Z")   # month 13
  doAssert not isRfc3339("2026-07-32T09:30:00Z")   # day 32
  doAssert not isRfc3339("2026-07-12T24:30:00Z")   # hour 24
  doAssert not isRfc3339("2026-07-12T09:60:00Z")   # minute 60
  doAssert not isRfc3339("2026-07-12T09:30:00+24:00") # offset hour 24
  doAssert not isRfc3339("2026-07-12T09:30:00+00:60") # offset minute 60
  doAssert not isRfc3339("2026-07-12 09:30:00Z")   # space instead of T
  doAssert not isRfc3339("2026-07-12T09:30:00")     # no offset
  doAssert not isRfc3339("2026-07-12T09:30:00.Z")   # empty fraction
  doAssert not isRfc3339("2026-07-12T09:30:00+0000") # offset lacks colon
  doAssert not isRfc3339("2026-07-12T09:30:00Zextra") # trailing text
  for bad in ["2026-13-12T09:30:00Z", "2026-07-12T09:30:00", "garbage"]:
    doAssertRaises DecodeError:
      discard decodeTimestamp(%bad, "ts")

block rfc3339ValidatesCalendarDates:
  # Month lengths are enforced, honouring leap years.
  doAssert isRfc3339("2024-02-29T00:00:00Z")     # 2024 is a leap year
  doAssert not isRfc3339("2023-02-29T00:00:00Z") # 2023 is not
  doAssert not isRfc3339("2026-02-30T00:00:00Z") # February never has 30 days
  doAssert isRfc3339("2026-04-30T00:00:00Z")     # April has 30 days
  doAssert not isRfc3339("2026-04-31T00:00:00Z") # ...but not 31
  doAssert not isRfc3339("2026-00-10T00:00:00Z") # month 0
  doAssert not isRfc3339("2026-07-00T00:00:00Z") # day 0
  # The Gregorian century rule: 1900 is not a leap year, 2000 is.
  doAssert not isRfc3339("1900-02-29T00:00:00Z")
  doAssert isRfc3339("2000-02-29T00:00:00Z")
  # A Discord timestamp with microseconds still decodes.
  doAssert decodeTimestamp(
    %"2026-07-12T09:30:00.123456+00:00", "ts").iso8601 ==
    "2026-07-12T09:30:00.123456+00:00"

block rfc3339LeapSecondOnlyAtEndOfMinute:
  # A leap second (:60) is accepted only as the last second of a minute, the
  # only place a real UTC leap second occurs, including under an offset.
  doAssert isRfc3339("2016-12-31T23:59:60Z")
  doAssert isRfc3339("2016-12-31T15:59:60-08:00") # the same leap instant
  doAssert not isRfc3339("2026-07-12T09:30:60Z")  # :60 not at minute 59
  doAssert not isRfc3339("2026-07-12T09:30:61Z")  # seconds never reach 61
  doAssertRaises DecodeError:
    discard decodeTimestamp(%"2026-07-12T09:30:60Z", "ts")

block permissionsRoundTripUnknownBits:
  # sendMessages is bit 11 (2048); decode must recognize it.
  let perms = decodePermissions(%"2048", "perms")
  doAssert $perms == "2048"
  doAssert perms.contains(Permission.sendMessages)
  # A value with a bit position beyond 64 (unknown to Permission) must survive.
  let wide = decodePermissions(%"18446744073709551616", "perms") # 2^64
  doAssert $wide == "18446744073709551616"
  doAssertRaises DecodeError:
    discard decodePermissions(%5, "perms")

block partialEmojiCustomAndUnicode:
  let custom = decodePartialEmoji(
    %*{"id": "41771983429993937", "name": "tada", "animated": true}, "emoji")
  doAssert custom.id.isSome
  doAssert custom.id.get.toUint64 == 41771983429993937'u64
  doAssert custom.name == some("tada")
  doAssert custom.animated == some(true)
  let unicode = decodePartialEmoji(%*{"id": newJNull(), "name": "🎉"}, "emoji")
  doAssert unicode.id.isNone
  doAssert unicode.name == some("🎉")

block openEnumRetainsUnknownValue:
  type Sample = enum saOne = 1
  let known = decodeIntEnum(Sample, %1, "sample")
  doAssert known.knownValue == some(saOne)
  let unknown = decodeIntEnum(Sample, %999, "sample")
  doAssert unknown.knownValue.isNone
  doAssert unknown.toRaw == 999

block parseJsonObjectRejectsNonObject:
  doAssert parseJsonObject("{\"a\":1}", "ctx").kind == JObject
  doAssertRaises DecodeError:
    discard parseJsonObject("[1,2]", "ctx")
  doAssertRaises DecodeError:
    discard parseJsonObject("not json", "ctx")
