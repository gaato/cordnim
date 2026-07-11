## Forward-compatible enum values that preserve unknown wire values.

import std/[enumutils, hashes, options, typetraits]

type
  OpenEnum*[E, Raw] = object ## A wire enum value that may be newer than this
                             ## library.
    raw*: Raw ## Exact wire value retained for round-trip encoding.

iterator declaredMembers[T: enum](enumType: typedesc[T]): T =
  when T is HoleyEnum:
    for value in enumutils.items(enumType):
      yield value
  else:
    for value in enumType:
      yield value

func initOpenEnum*[E](raw: auto): OpenEnum[E, typeof(raw)] {.inline.} =
  ## Wraps an untrusted wire value without requiring it to be known.
  OpenEnum[E, typeof(raw)](raw: raw)

func toRaw*[E, Raw](value: OpenEnum[E, Raw]): Raw {.inline.} =
  ## Returns the exact stored wire value.
  value.raw

func knownValue*[E: enum, Raw: SomeInteger](
    value: OpenEnum[E, Raw]): Option[E] =
  ## Returns the declared enum member matching the raw ordinal.
  ##
  ## Iterating declared members also handles enums with ordinal holes.
  for known in declaredMembers(E):
    let ordinal = ord(known)
    when Raw is SomeUnsignedInt:
      if ordinal >= 0 and
          BiggestUInt(value.raw) == BiggestUInt(ordinal):
        return some(known)
    else:
      if BiggestInt(value.raw) == BiggestInt(ordinal):
        return some(known)
  none(E)

func isKnown*[E: enum, Raw: SomeInteger](
    value: OpenEnum[E, Raw]): bool =
  ## Tests whether the raw value matches a declared member of `E`.
  value.knownValue.isSome

proc requireKnown*[E: enum, Raw: SomeInteger](
    value: OpenEnum[E, Raw]): E =
  ## Returns the known member or raises `ValueError` for a future value.
  let known = value.knownValue
  if known.isNone:
    raise newException(ValueError, "unknown Discord enum value: " &
      $value.raw)
  known.get

proc toOpenEnum*[Raw: SomeInteger, E: enum](
    value: E; rawType: typedesc[Raw]): OpenEnum[E, Raw] =
  ## Converts a known enum member to a chosen integer wire type.
  let ordinal = ord(value)
  when Raw is SomeUnsignedInt:
    if ordinal < 0 or BiggestUInt(ordinal) > BiggestUInt(high(Raw)):
      raise newException(ValueError, "enum ordinal does not fit wire type")
  else:
    if BiggestInt(ordinal) < BiggestInt(low(Raw)) or
        BiggestInt(ordinal) > BiggestInt(high(Raw)):
      raise newException(ValueError, "enum ordinal does not fit wire type")
  OpenEnum[E, Raw](raw: Raw(ordinal))

func `==`*[E, Raw](left, right: OpenEnum[E, Raw]): bool {.inline.} =
  ## Compares exact wire values within the same enum domain.
  left.raw == right.raw

func hash*[E, Raw](value: OpenEnum[E, Raw]): Hash {.inline.} =
  ## Hashes the exact wire value, including values unknown to `E`.
  hash(value.raw)

func `$`*[E, Raw](value: OpenEnum[E, Raw]): string =
  ## Formats the exact wire value without substituting an enum label.
  $value.raw
