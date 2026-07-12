## Forward-compatible JSON model helpers used by generated raw types.

import std/[json, options]

import ../core/[bits, fields, ids, open_enums]

export bits, fields, ids, open_enums

type
  RawModelError* = object of ValueError ## Invalid use or decoding of a raw
    ## schema model.

  RawEnumValue*[T] = object ## Forward-compatible enum storage retaining its
    ## wire value.
    raw*: T ## Unmodified wire value; known values are only a view.

  RawField* = object ## Unknown JSON object field preserved by a semantic
    ## decoder.
    name*: string ## Original JSON property name.
    value*: JsonNode ## Complete original JSON value.

  JsonValueDecoder*[T] = proc(node: JsonNode): T
    ## Caller-supplied conversion from one JSON value to a domain type.

  JsonValueEncoder*[T] = proc(value: T): JsonNode
    ## Caller-supplied conversion from one domain value to JSON.

func initRawEnumValue*[T](raw: T): RawEnumValue[T] =
  ## Wraps a wire enum value without rejecting future values.
  RawEnumValue[T](raw: raw)

func isKnown*[T](value: RawEnumValue[T], knownValues: openArray[T]): bool =
  ## Tests whether the stored wire value appears in `knownValues`.
  for known in knownValues:
    if value.raw == known:
      return true

func knownValue*[T](
    value: RawEnumValue[T], knownValues: openArray[T]
): Option[T] =
  ## Returns the stored value only when it appears in `knownValues`.
  if value.isKnown(knownValues):
    some(value.raw)
  else:
    none(T)

proc decodeModel*[T](modelType: typedesc[T], raw: sink JsonNode): T =
  ## Decodes without discarding fields unknown to this schema revision.
  if raw.isNil:
    raise newException(RawModelError, "cannot decode a nil JSON node")
  when compiles(result.raw):
    # Generated models own the complete JSON tree; semantic projections must
    # not rebuild it and accidentally discard fields introduced by Discord.
    result.raw = raw
  else:
    {.error: "decodeModel requires a generated raw model type".}

func toJson*[T](value: T): JsonNode =
  ## Returns the complete original JSON tree, including unknown fields.
  when compiles(value.raw):
    value.raw
  else:
    {.error: "toJson requires a generated raw model type".}

func unknownFields*(
    raw: JsonNode, knownNames: openArray[string]
): seq[RawField] =
  ## Extracts fields not recognized by a higher-level semantic model.
  if raw.isNil or raw.kind != JObject:
    return
  for name, value in raw:
    if name notin knownNames:
      result.add(RawField(name: name, value: value))

proc requireJsonObject(raw: JsonNode; description: string) =
  if raw.isNil or raw.kind != JObject:
    raise newException(RawModelError, description & " must be a JSON object")

proc decodeDiscordField*[T](
    raw: JsonNode; propertyName: string;
    decodeValue: JsonValueDecoder[T]
): DiscordField[T] =
  ## Decodes omission, explicit null, or a caller-typed property value.
  ##
  ## The decoder is invoked only for a present, non-null value. This helper
  ## does not infer a domain type from the OpenAPI descriptor registry.
  raw.requireJsonObject("raw model")
  if not raw.hasKey(propertyName):
    return absent[T]()
  if raw[propertyName].kind == JNull:
    return nullValue[T]()
  if decodeValue.isNil:
    raise newException(RawModelError, "JSON value decoder must not be nil")
  present(decodeValue(raw[propertyName]))

proc encodeDiscordFieldProperty*[T](
    destination: JsonNode; propertyName: string;
    field: DiscordField[T]; encodeValue: JsonValueEncoder[T]
) =
  ## Writes one three-state field into an outbound JSON object.
  ##
  ## `Absent` removes the property, `NullValue` writes JSON null, and
  ## `Present` delegates encoding to the caller.
  destination.requireJsonObject("field destination")
  case field.kind
  of FieldKind.Absent:
    destination.delete(propertyName)
  of FieldKind.NullValue:
    destination[propertyName] = newJNull()
  of FieldKind.Present:
    if encodeValue.isNil:
      raise newException(RawModelError, "JSON value encoder must not be nil")
    let encoded = encodeValue(field.value)
    if encoded.isNil:
      raise newException(RawModelError, "JSON value encoder returned nil")
    destination[propertyName] = encoded

proc encodePatchProperty*[T](
    destination: JsonNode; propertyName: string; patch: Patch[T];
    encodeValue: JsonValueEncoder[T]
) =
  ## Writes one PATCH field while preserving omit, clear, and set semantics.
  ##
  ## `LeaveUnchanged` removes the property from the outbound patch object.
  destination.requireJsonObject("patch destination")
  case patch.kind
  of PatchKind.LeaveUnchanged:
    destination.delete(propertyName)
  of PatchKind.ClearValue:
    destination[propertyName] = newJNull()
  of PatchKind.SetValue:
    if encodeValue.isNil:
      raise newException(RawModelError, "JSON value encoder must not be nil")
    let encoded = encodeValue(patch.value)
    if encoded.isNil:
      raise newException(RawModelError, "JSON value encoder returned nil")
    destination[propertyName] = encoded

proc decodeId*[Kind](
    idType: typedesc[Id[Kind]]; raw: JsonNode
): Id[Kind] =
  ## Decodes a snowflake from its canonical decimal-string JSON boundary.
  if raw.isNil or raw.kind != JString:
    raise newException(
      RawModelError,
      "Discord snowflake must be a decimal JSON string",
    )
  try:
    result = parseId[Kind](raw.getStr)
  except ValueError as error:
    raise newException(RawModelError, error.msg)

func toJson*[Kind](value: Id[Kind]): JsonNode =
  ## Encodes a typed snowflake in canonical decimal-string form.
  newJString($value)

proc decodeDiscordBits*[Domain](
    bitsType: typedesc[DiscordBits[Domain]]; raw: JsonNode;
    maxDigits: Natural = defaultMaxBitsDigits
): DiscordBits[Domain] =
  ## Decodes arbitrary-width flags from a decimal JSON string.
  if raw.isNil or raw.kind != JString:
    raise newException(
      RawModelError,
      "Discord bit field must be a decimal JSON string",
    )
  try:
    result = parseDiscordBits[Domain](raw.getStr, maxDigits)
  except ValueError as error:
    raise newException(RawModelError, error.msg)

func toJson*[Domain](value: DiscordBits[Domain]): JsonNode =
  ## Encodes arbitrary-width flags without dropping unknown high bits.
  newJString(value.toDecimal)

proc decodeOpenEnum*[E, Raw](
    enumType: typedesc[E]; rawType: typedesc[Raw]; raw: JsonNode
): OpenEnum[E, Raw] =
  ## Decodes an enum wire value while retaining values unknown to `E`.
  ##
  ## Integer-backed values use ordinal convenience helpers. For string-backed
  ## values, pass the generated or caller-owned mapping to `knownValue`,
  ## `isKnown`, `requireKnown`, or `toOpenEnum`.
  when Raw is string:
    if raw.isNil or raw.kind != JString:
      raise newException(RawModelError, "enum wire value must be a string")
    result = initOpenEnum[E](raw.getStr)
  elif Raw is SomeInteger:
    if raw.isNil or raw.kind != JInt:
      raise newException(RawModelError, "enum wire value must be an integer")
    let value = raw.getBiggestInt
    when Raw is SomeUnsignedInt:
      if value < 0 or BiggestUInt(value) > BiggestUInt(high(Raw)):
        raise newException(RawModelError, "enum wire value is out of range")
    else:
      if value < BiggestInt(low(Raw)) or value > BiggestInt(high(Raw)):
        raise newException(RawModelError, "enum wire value is out of range")
    result = initOpenEnum[E](Raw(value))
  else:
    {.error: "decodeOpenEnum supports string and integer wire values".}

func toJson*[E, Raw](value: OpenEnum[E, Raw]): JsonNode =
  ## Encodes the exact enum wire value, including unknown values.
  when Raw is string:
    newJString(value.raw)
  elif Raw is SomeUnsignedInt:
    if BiggestUInt(value.raw) > BiggestUInt(high(BiggestInt)):
      raise newException(RawModelError, "enum wire value exceeds JSON integer")
    newJInt(BiggestInt(value.raw))
  elif Raw is SomeSignedInt:
    newJInt(BiggestInt(value.raw))
  else:
    {.error: "toJson supports string and integer enum wire values".}
