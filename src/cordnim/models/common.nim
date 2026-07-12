## Shared building blocks for handwritten semantic Discord resource models.
##
## The semantic model layer turns Discord's wire JSON into plain value objects
## that later high-level REST calls, typed Gateway events, and the cache can
## reuse. Unlike the generated `raw` layer, these types name their fields and
## reject malformed required data, while still retaining every original byte
## for forward compatibility.
##
## Decoders raise `DecodeError` (the repository's `dekDecode` failure category)
## rather than returning a `Result`; callers that want a non-raising view can
## wrap a decode in the existing `rest/checked` helpers. No decoder raises a
## bare `ValueError` or `KeyError` across the public boundary.

import std/[json, options, strutils]

import ../core/bits
import ../core/errors
import ../core/fields
import ../core/ids
import ../core/open_enums
import ../core/permissions

export options
export bits
export errors
export fields
export ids
export open_enums
export permissions

type
  UnknownField* = object ## A JSON property that a decoder did not consume.
    name*: string ## Original JSON property name as sent by Discord.
    value*: JsonNode ## Deep copy of the original JSON value, owned by the
                     ## caller and safe to mutate.

  DiscordSnapshot* = object ## Retained decode evidence for one semantic object.
    ##
    ## The stored JSON tree is private so callers cannot mutate the snapshot a
    ## decoded value depends on; use `rawJson` and `unknownFields` to obtain
    ## independent deep copies.
    raw: JsonNode ## Complete original object, deep copied at decode time.
    unknown: seq[UnknownField] ## Fields not consumed by the decoder.

  Timestamp* = object ## An ISO 8601 instant exactly as Discord serialized it.
    ##
    ## The wire text is preserved verbatim so re-encoding never loses Discord's
    ## fractional-second or offset formatting.
    iso: string ## Original ISO 8601 string.

func raiseDecode*(message: string) {.noreturn.} =
  ## Raises a `DecodeError` with `message`, the repository's decode failure.
  raise newDiscordError(DecodeError, message)

func iso8601*(stamp: Timestamp): string {.inline.} =
  ## Returns the original ISO 8601 wire text of `stamp`.
  stamp.iso

func `$`*(stamp: Timestamp): string {.inline.} =
  ## Formats the timestamp as its original ISO 8601 text.
  stamp.iso

func `==`*(left, right: Timestamp): bool {.inline.} =
  ## Compares two timestamps by their exact wire text.
  left.iso == right.iso

proc ensureObject*(node: JsonNode; context: string): JsonNode =
  ## Returns `node` when it is a JSON object, otherwise raises `DecodeError`.
  if node.isNil or node.kind != JObject:
    raiseDecode(context & " must be a JSON object")
  node

proc requireField*(obj: JsonNode; name, owner: string): JsonNode =
  ## Returns a present, non-null property or raises `DecodeError`.
  ##
  ## A required field that is omitted or explicitly `null` is rejected, because
  ## a full Discord resource always carries it.
  if not obj.hasKey(name) or obj[name].kind == JNull:
    raiseDecode(owner & " is missing required field '" & name & "'")
  obj[name]

proc requireNullable*(obj: JsonNode; name, owner: string): Option[JsonNode] =
  ## Returns a required, nullable property, distinguishing null from absence.
  ##
  ## The property must be present, because a full Discord resource always
  ## carries it; omission is a `DecodeError`. An explicit `null` yields `none`,
  ## while any other value yields `some`. Use this for fields the pinned schema
  ## marks required yet permits to be `null`.
  if not obj.hasKey(name):
    raiseDecode(owner & " is missing required field '" & name & "'")
  let value = obj[name]
  if value.kind == JNull:
    none(JsonNode)
  else:
    some(value)

proc jsonKindLabel(kinds: set[JsonNodeKind]): string =
  ## Renders an expected-kind set for a decode error message.
  var parts: seq[string]
  for kind in kinds:
    parts.add(
      case kind
      of JString: "string"
      of JInt: "integer"
      of JFloat: "number"
      of JBool: "boolean"
      of JObject: "object"
      of JArray: "array"
      of JNull: "null")
  parts.join(" or ")

proc requireNonNull*(obj: JsonNode; name, owner: string;
    kinds: set[JsonNodeKind] = {}) =
  ## Enforces a required, present, non-null property the semantic type does not
  ## decode into a value.
  ##
  ## Rejects both omission and an explicit `null`. When `kinds` is non-empty the
  ## actual JSON type is validated too, so a required non-null field cannot slip
  ## through with the wrong shape. Use this in place of a bare presence check
  ## for fields the pinned schema marks required and non-null.
  let value = requireField(obj, name, owner)
  if kinds != {} and value.kind notin kinds:
    raiseDecode(owner & " field '" & name & "' must be a " &
      jsonKindLabel(kinds))

proc requireNullablePresent*(obj: JsonNode; name, owner: string;
    kinds: set[JsonNodeKind] = {}) =
  ## Enforces a required property that may be `null` but must be present.
  ##
  ## Omission is rejected; an explicit `null` is accepted. When `kinds` is
  ## non-empty a non-null value's JSON type is validated. Use this for fields
  ## the pinned schema marks required and nullable that the semantic type does
  ## not decode into a value.
  if not obj.hasKey(name):
    raiseDecode(owner & " is missing required field '" & name & "'")
  let value = obj[name]
  if value.kind != JNull and kinds != {} and value.kind notin kinds:
    raiseDecode(owner & " field '" & name & "' must be a " &
      jsonKindLabel(kinds) & " or null")

proc requireNonNullKeys*(obj: JsonNode; owner: string;
    names: openArray[string]) =
  ## Enforces that every listed property is present and non-null.
  for name in names:
    requireNonNull(obj, name, owner)

proc requireNullablePresentKeys*(obj: JsonNode; owner: string;
    names: openArray[string]) =
  ## Enforces that every listed property is present, permitting `null`.
  for name in names:
    requireNullablePresent(obj, name, owner)

proc optionalField*(obj: JsonNode; name: string): Option[JsonNode] =
  ## Returns a present, non-null property, or `none` for absent or `null`.
  ##
  ## This collapses omission and explicit `null`; use `fieldState` when the two
  ## must be distinguished. This is the optional *nullable* reading, where a
  ## `null` carries no more meaning than absence.
  if not obj.hasKey(name):
    return none(JsonNode)
  let value = obj[name]
  if value.kind == JNull:
    none(JsonNode)
  else:
    some(value)

proc optionalNonNullField*(obj: JsonNode; name, owner: string): Option[JsonNode] =
  ## Returns a present value, `none` for absence, and rejects explicit `null`.
  ##
  ## Use this for optional *non-null* properties, where the schema permits
  ## omission but never `null`; an explicit `null` is a malformed payload rather
  ## than an absent value, so it is not collapsed to `none`.
  if not obj.hasKey(name):
    return none(JsonNode)
  let value = obj[name]
  if value.kind == JNull:
    raiseDecode(owner & " field '" & name & "' must not be null")
  some(value)

proc fieldState*(obj: JsonNode; name: string): DiscordField[JsonNode] =
  ## Returns the three-state presence of a property: absent, null, or value.
  ##
  ## Use this only where Discord's omit-versus-`null` distinction is
  ## meaningful; the stored node is not copied and must not be mutated.
  if not obj.hasKey(name):
    return absent[JsonNode]()
  let value = obj[name]
  if value.kind == JNull:
    nullValue[JsonNode]()
  else:
    present(value)

proc asString*(node: JsonNode; context: string): string =
  ## Returns the JSON string value or raises `DecodeError` on the wrong type.
  if node.kind != JString:
    raiseDecode(context & " must be a JSON string")
  node.getStr

proc asBool*(node: JsonNode; context: string): bool =
  ## Returns the JSON boolean value or raises `DecodeError` on the wrong type.
  if node.kind != JBool:
    raiseDecode(context & " must be a JSON boolean")
  node.getBool

proc asInt*(node: JsonNode; context: string): int64 =
  ## Returns the JSON integer value or raises `DecodeError` on the wrong type.
  if node.kind != JInt:
    raiseDecode(context & " must be a JSON integer")
  node.getBiggestInt

proc asArray*(node: JsonNode; context: string): seq[JsonNode] =
  ## Returns the JSON array elements or raises `DecodeError` on the wrong type.
  if node.kind != JArray:
    raiseDecode(context & " must be a JSON array")
  node.elems

proc decodeId*[Kind](idType: typedesc[Id[Kind]]; node: JsonNode;
    context: string): Id[Kind] =
  ## Decodes a snowflake from its canonical decimal-string JSON form.
  ##
  ## A non-string node or a malformed snowflake is rejected as a `DecodeError`.
  if node.kind != JString:
    raiseDecode(context & " must be a decimal snowflake string")
  try:
    parseId[Kind](node.getStr)
  except ValueError as error:
    raiseDecode(context & ": " & error.msg)

proc decodePermissions*(node: JsonNode; context: string): Permissions =
  ## Decodes an arbitrary-width permission bit field from a decimal string.
  ##
  ## Bits unknown to `Permission` survive so future permissions round-trip.
  if node.kind != JString:
    raiseDecode(context & " must be a decimal permissions string")
  try:
    parsePermissions(node.getStr)
  except ValueError as error:
    raiseDecode(context & ": " & error.msg)

func twoDigits(text: string; pos: int): int =
  ## Reads exactly two ASCII digits at `pos`, or returns -1 when absent.
  if pos + 1 >= text.len or
      text[pos] notin {'0'..'9'} or text[pos + 1] notin {'0'..'9'}:
    -1
  else:
    (ord(text[pos]) - ord('0')) * 10 + (ord(text[pos + 1]) - ord('0'))

func isLeapYear(year: int): bool {.inline.} =
  ## Applies the proleptic Gregorian leap-year rule.
  (year mod 4 == 0 and year mod 100 != 0) or year mod 400 == 0

func daysInMonth(year, month: int): int =
  ## Returns the number of days in `month` of `year`, or 0 for an out-of-range
  ## month.
  case month
  of 1, 3, 5, 7, 8, 10, 12: 31
  of 4, 6, 9, 11: 30
  of 2: (if isLeapYear(year): 29 else: 28)
  else: 0

func isRfc3339*(text: string): bool =
  ## Validates a calendar-correct RFC 3339 `date-time`, including offsets.
  ##
  ## Requires `YYYY-MM-DDThh:mm:ss` followed by an optional fractional second
  ## and either `Z`/`z` or a numeric `±hh:mm` offset that consumes the rest of
  ## the string. Component ranges are checked (month 01-12, hour 00-23, minute
  ## 00-59, offset hour 00-23 and minute 00-59) and the day is validated
  ## against the actual month length, honouring Gregorian leap years. A second
  ## value of 60 is accepted only as the last second of a minute (`mm` == 59),
  ## the sole position a UTC leap second can occupy, and is rejected anywhere
  ## else. The text is only inspected, never rewritten.
  if text.len < 20: # "YYYY-MM-DDThh:mm:ssZ" is the shortest legal form.
    return false
  for i in 0 .. 3:
    if text[i] notin {'0'..'9'}: return false
  let year = (ord(text[0]) - ord('0')) * 1000 +
    (ord(text[1]) - ord('0')) * 100 +
    (ord(text[2]) - ord('0')) * 10 + (ord(text[3]) - ord('0'))
  if text[4] != '-': return false
  let month = twoDigits(text, 5)
  if month < 1 or month > 12: return false
  if text[7] != '-': return false
  let mday = twoDigits(text, 8)
  if mday < 1 or mday > daysInMonth(year, month): return false
  if text[10] notin {'T', 't'}: return false
  let hour = twoDigits(text, 11)
  if hour < 0 or hour > 23: return false
  if text[13] != ':': return false
  let minute = twoDigits(text, 14)
  if minute < 0 or minute > 59: return false
  if text[16] != ':': return false
  let second = twoDigits(text, 17)
  if second < 0 or second > 60: return false
  if second == 60 and minute != 59:
    return false # a leap second only ever occurs as the 60th second of :59.
  var pos = 19
  if pos < text.len and text[pos] == '.':
    inc pos
    let start = pos
    while pos < text.len and text[pos] in {'0'..'9'}: inc pos
    if pos == start: return false # a fractional dot needs at least one digit
  if pos >= text.len: return false
  if text[pos] in {'Z', 'z'}:
    return pos == text.high # nothing may follow the zone designator
  if text[pos] notin {'+', '-'}: return false
  inc pos
  let offsetHour = twoDigits(text, pos)
  if offsetHour < 0 or offsetHour > 23: return false
  pos += 2
  if pos >= text.len or text[pos] != ':': return false
  inc pos
  let offsetMinute = twoDigits(text, pos)
  if offsetMinute < 0 or offsetMinute > 59: return false
  pos += 2
  pos == text.len

proc decodeTimestamp*(node: JsonNode; context: string): Timestamp =
  ## Decodes an RFC 3339 timestamp string, preserving its exact wire text.
  ##
  ## The string is validated lexically, including offset ranges, before it is
  ## stored; the retained text is byte-for-byte identical to the wire value.
  if node.kind != JString:
    raiseDecode(context & " must be an RFC 3339 timestamp string")
  let text = node.getStr
  if not isRfc3339(text):
    raiseDecode(context & " must be a valid RFC 3339 timestamp")
  Timestamp(iso: text)

proc decodeIntEnum*[E](enumType: typedesc[E]; node: JsonNode;
    context: string): OpenEnum[E, int] =
  ## Decodes an integer-backed Discord enum, retaining unknown wire values.
  ##
  ## The declared members of `E` are only a view; a value newer than this
  ## library survives via `toRaw`.
  if node.kind != JInt:
    raiseDecode(context & " must be an integer enum value")
  let value = node.getBiggestInt
  if value < int64(low(int)) or value > int64(high(int)):
    raiseDecode(context & " enum value is out of range")
  initOpenEnum[E](int(value))

proc decodeStringEnum*[E](enumType: typedesc[E]; node: JsonNode;
    context: string): OpenEnum[E, string] =
  ## Decodes a string-backed Discord enum, retaining unknown wire values.
  if node.kind != JString:
    raiseDecode(context & " must be a string enum value")
  initOpenEnum[E](node.getStr)

proc optString*(obj: JsonNode; name, owner: string): Option[string] =
  ## Decodes an optional, nullable string property.
  let node = optionalField(obj, name)
  if node.isSome:
    some(asString(node.get, owner & "." & name))
  else:
    none(string)

proc optBool*(obj: JsonNode; name, owner: string): Option[bool] =
  ## Decodes an optional, nullable boolean property.
  let node = optionalField(obj, name)
  if node.isSome:
    some(asBool(node.get, owner & "." & name))
  else:
    none(bool)

proc optInt*(obj: JsonNode; name, owner: string): Option[int64] =
  ## Decodes an optional, nullable integer property.
  let node = optionalField(obj, name)
  if node.isSome:
    some(asInt(node.get, owner & "." & name))
  else:
    none(int64)

proc optNonNullBool*(obj: JsonNode; name, owner: string): Option[bool] =
  ## Decodes an optional, non-null boolean property.
  ##
  ## Absence yields `none`; an explicit `null` is rejected rather than collapsed
  ## to absence, because the schema marks the field non-null.
  let node = optionalNonNullField(obj, name, owner)
  if node.isSome:
    some(asBool(node.get, owner & "." & name))
  else:
    none(bool)

proc optNonNullString*(obj: JsonNode; name, owner: string): Option[string] =
  ## Decodes an optional, non-null string property.
  ##
  ## Absence yields `none`; an explicit `null` is rejected rather than collapsed
  ## to absence, because the schema marks the field optional yet non-null.
  let node = optionalNonNullField(obj, name, owner)
  if node.isSome:
    some(asString(node.get, owner & "." & name))
  else:
    none(string)

proc optNonNullInt*(obj: JsonNode; name, owner: string): Option[int64] =
  ## Decodes an optional, non-null integer property.
  ##
  ## Absence yields `none`; an explicit `null` is rejected, since these fields
  ## are non-null when present and `null` is a malformed payload, not absence.
  let node = optionalNonNullField(obj, name, owner)
  if node.isSome:
    some(asInt(node.get, owner & "." & name))
  else:
    none(int64)

proc optNonNullId*[Kind](idType: typedesc[Id[Kind]]; obj: JsonNode; name,
    owner: string): Option[Id[Kind]] =
  ## Decodes an optional, non-null snowflake property.
  ##
  ## Absence yields `none`; an explicit `null` is rejected. Use this for
  ## snowflake fields the schema marks optional yet never nullable, so a `null`
  ## is a malformed payload rather than an omitted value.
  let node = optionalNonNullField(obj, name, owner)
  if node.isSome:
    some(decodeId(idType, node.get, owner & "." & name))
  else:
    none(Id[Kind])

proc optNonNullArray*(obj: JsonNode; name, owner: string): Option[seq[JsonNode]] =
  ## Returns the elements of an optional, non-null array property.
  ##
  ## Absence yields `none`; an explicit `null` and a non-array value are both
  ## rejected. Use this for array fields the schema marks optional yet non-null,
  ## where a `null` would be a malformed payload rather than an absent list.
  let node = optionalNonNullField(obj, name, owner)
  if node.isSome:
    some(asArray(node.get, owner & "." & name))
  else:
    none(seq[JsonNode])

proc optNonNullObject*(obj: JsonNode; name, owner: string): Option[JsonNode] =
  ## Returns an optional, non-null object property, rejecting `null` and non-objects.
  ##
  ## Absence yields `none`; an explicit `null` and a non-object value are both
  ## rejected. Use this for nested-object fields the schema marks optional yet
  ## non-null before handing the node to a dedicated decoder.
  let node = optionalNonNullField(obj, name, owner)
  if node.isSome:
    some(ensureObject(node.get, owner & "." & name))
  else:
    none(JsonNode)

proc expectOptionalNullable*(obj: JsonNode; name, owner: string;
    kinds: set[JsonNodeKind]) =
  ## Type-checks an optional, nullable property the semantic type does not decode.
  ##
  ## Absence and an explicit `null` are both accepted; a present non-null value
  ## of the wrong JSON type is rejected. Use this to validate an unmodelled
  ## optional-nullable field that is otherwise carried only in the snapshot.
  if not obj.hasKey(name):
    return
  let value = obj[name]
  if value.kind != JNull and kinds != {} and value.kind notin kinds:
    raiseDecode(owner & " field '" & name & "' must be a " &
      jsonKindLabel(kinds) & " or null")

proc boolOr*(obj: JsonNode; name: string; fallback: bool; owner: string): bool =
  ## Decodes an optional, non-null boolean that Discord omits to mean `fallback`.
  ##
  ## Omission yields `fallback`; an explicit `null` is rejected, since these
  ## fields are non-null when present and `null` would be a malformed payload
  ## rather than the default.
  let node = optionalNonNullField(obj, name, owner)
  if node.isSome:
    asBool(node.get, owner & "." & name)
  else:
    fallback

proc optId*[Kind](idType: typedesc[Id[Kind]]; obj: JsonNode; name,
    owner: string): Option[Id[Kind]] =
  ## Decodes an optional, nullable snowflake property.
  let node = optionalField(obj, name)
  if node.isSome:
    some(decodeId(idType, node.get, owner & "." & name))
  else:
    none(Id[Kind])

proc optTimestamp*(obj: JsonNode; name, owner: string): Option[Timestamp] =
  ## Decodes an optional, nullable ISO 8601 timestamp property.
  let node = optionalField(obj, name)
  if node.isSome:
    some(decodeTimestamp(node.get, owner & "." & name))
  else:
    none(Timestamp)

proc reqNullableString*(obj: JsonNode; name, owner: string): Option[string] =
  ## Decodes a required string property that Discord may send as `null`.
  ##
  ## Absence is rejected; an explicit `null` yields `none`.
  let node = requireNullable(obj, name, owner)
  if node.isSome:
    some(asString(node.get, owner & "." & name))
  else:
    none(string)

proc reqNullableInt*(obj: JsonNode; name, owner: string): Option[int64] =
  ## Decodes a required integer property that Discord may send as `null`.
  ##
  ## Absence is rejected; an explicit `null` yields `none`.
  let node = requireNullable(obj, name, owner)
  if node.isSome:
    some(asInt(node.get, owner & "." & name))
  else:
    none(int64)

proc reqNullableTimestamp*(obj: JsonNode; name,
    owner: string): Option[Timestamp] =
  ## Decodes a required timestamp property that Discord may send as `null`.
  let node = requireNullable(obj, name, owner)
  if node.isSome:
    some(decodeTimestamp(node.get, owner & "." & name))
  else:
    none(Timestamp)

proc reqNullableId*[Kind](idType: typedesc[Id[Kind]]; obj: JsonNode; name,
    owner: string): Option[Id[Kind]] =
  ## Decodes a required snowflake property that Discord may send as `null`.
  let node = requireNullable(obj, name, owner)
  if node.isSome:
    some(decodeId(idType, node.get, owner & "." & name))
  else:
    none(Id[Kind])

proc initSnapshot*(obj: JsonNode; consumed: openArray[string]): DiscordSnapshot =
  ## Captures a deep copy of `obj` and the fields not named in `consumed`.
  ##
  ## `obj` must already be validated as a JSON object. Property names absent
  ## from `consumed` are retained as unknown fields for forward compatibility.
  result.raw = obj.copy()
  for name, value in obj:
    if name notin consumed:
      result.unknown.add(UnknownField(name: name, value: value.copy()))

proc rawJson*(snapshot: DiscordSnapshot): JsonNode =
  ## Returns an independent deep copy of the original decoded JSON object.
  snapshot.raw.copy()

proc unknownFields*(snapshot: DiscordSnapshot): seq[UnknownField] =
  ## Returns deep copies of every field the decoder did not consume.
  ##
  ## Each value is copied again on access so callers cannot mutate the stored
  ## snapshot through a returned node.
  for field in snapshot.unknown:
    result.add(UnknownField(name: field.name, value: field.value.copy()))

func repr*(snapshot: DiscordSnapshot): string =
  ## Renders a snapshot opaquely for `repr`, without traversing its raw JSON.
  ##
  ## Nim's generic `repr` would otherwise walk the retained JSON tree of any
  ## value that embeds a snapshot, exposing whatever the payload held. Because
  ## the `Webhook` snapshot deliberately still names credential fields (with
  ## their values already scrubbed), keeping the raw tree out of every generic
  ## representation is defence in depth: no containing public type can leak a
  ## snapshot's contents through `repr`. Use `rawJson`/`unknownFields` for the
  ## real data.
  "DiscordSnapshot(fields: " & $(snapshot.unknown.len) & " unknown)"

type
  PartialEmoji* = object ## A reaction or media emoji, custom or unicode.
    ##
    ## Custom emoji carry an `id`; a unicode emoji carries only its `name`.
    id*: Option[EmojiId] ## Custom emoji snowflake, when custom.
    name*: Option[string] ## Emoji name or unicode character, when present.
    animated*: Option[bool] ## Whether a custom emoji is animated, when known.

proc decodePartialEmoji*(node: JsonNode; context: string): PartialEmoji =
  ## Decodes a partial emoji object with an optional id and name.
  let obj = ensureObject(node, context)
  result.id = optId(EmojiId, obj, "id", context)
  result.name = optString(obj, "name", context)
  result.animated = optBool(obj, "animated", context)

proc parseJsonObject*(text: string; context: string): JsonNode =
  ## Parses `text` and requires a top-level JSON object, else `DecodeError`.
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError as error:
    raiseDecode(context & " is not valid JSON: " & error.msg)
  ensureObject(node, context)
