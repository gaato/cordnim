## Forward-compatible JSON model helpers used by generated raw types.

import std/[json, options]

type
  RawModelError* = object of ValueError ## Invalid use or decoding of a raw schema model.

  RawEnumValue*[T] = object ## Forward-compatible enum storage retaining its wire value.
    raw*: T ## Unmodified wire value; known values are only a view.

  RawField* = object ## Unknown JSON object field preserved by a semantic decoder.
    name*: string ## Original JSON property name.
    value*: JsonNode ## Complete original JSON value.

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
    var known = false
    for knownName in knownNames:
      if name == knownName:
        known = true
        break
    if not known:
      result.add RawField(name: name, value: value)
