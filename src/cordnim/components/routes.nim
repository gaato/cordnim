## Signed, versioned, expiring component route codec.
##
## The cryptographic primitive is injected so applications can use a reviewed
## HMAC-SHA-256 implementation. Encoding fails when no active signing key or
## signer is configured; unsigned routes are never emitted.

import std/[base64, options, strutils]

const
  RouteSignatureBytes* = 16 ## Truncated HMAC bytes carried in `custom_id`.
  RouteHeaderBytes = 12
  MaxCustomIdBytes = 100

type
  RouteSigner* = proc(key, message: openArray[byte]): array[32, byte]
    {.gcsafe, raises: [].} ## Reviewed HMAC-SHA-256 provider.

  RouteSigningKey* = object ## One key in a rotation set.
    id*: uint8 ## Identifier stored in encoded routes.
    material*: seq[byte] ## Secret key bytes; callers must source them securely.

  RouteCodec* = object ## Configuration shared by route encoders and decoders.
    activeKeyId*: uint8 ## Key used for new routes.
    keys*: seq[RouteSigningKey] ## Active and retiring verification keys.
    signer*: RouteSigner ## HMAC-SHA-256 provider.

  RouteEnvelope* = object ## Verified routing metadata and opaque payload.
    routeTypeId*: uint16 ## Stable application-assigned route type.
    version*: uint8 ## Payload schema version.
    keyId*: uint8 ## Key that authenticated the route.
    expiresAt*: int64 ## Unix expiry timestamp.
    payload*: seq[byte] ## Application payload after verification.

  RouteDecodeError* = enum ## Route rejection reason.
    rdeNone, ## No error.
    rdeMalformed, ## Prefix, base64, or framing is invalid.
    rdeUnknownKey, ## Encoded key is no longer accepted.
    rdeSignatureRejected, ## Authentication tag did not match.
    rdeExpired, ## Route expiry is in the past.
    rdeSignerUnavailable ## No cryptographic provider is configured.

  RouteDecodeResult* = object ## Result of authenticating and decoding a route.
    case ok*: bool ## Whether authentication and decoding succeeded.
    of true:
      envelope*: RouteEnvelope ## Verified envelope.
    of false:
      error*: RouteDecodeError ## Rejection category.

func appendU16(destination: var seq[byte], value: uint16) =
  destination.add(byte(value shr 8))
  destination.add(byte(value and 0xff))

func appendU64(destination: var seq[byte], value: uint64) =
  for shift in countdown(56, 0, 8):
    destination.add(byte(value shr shift and 0xff))

func readU16(source: openArray[byte], offset: int): uint16 =
  uint16(source[offset]) shl 8 or uint16(source[offset + 1])

func readU64(source: openArray[byte], offset: int): uint64 =
  for index in offset ..< offset + 8:
    result = result shl 8 or uint64(source[index])

func withoutPadding(value: string): string =
  result = value
  while result.len > 0 and result[^1] == '=':
    result.setLen(result.len - 1)

func withPadding(value: string): string =
  result = value
  while result.len mod 4 != 0:
    result.add '='

func hasBase64UrlShape(value: string): bool =
  if value.len == 0 or value.len mod 4 == 1:
    return false
  for item in value:
    if item notin {'A'..'Z', 'a'..'z', '0'..'9', '-', '_'}:
      return false
  true

func constantTimeEqual(a, b: openArray[byte]): bool =
  if a.len != b.len:
    return false
  var difference = 0'u8
  for index in 0..<a.len:
    difference = difference or (a[index] xor b[index])
  difference == 0

func findKey(codec: RouteCodec, id: uint8): Option[RouteSigningKey] =
  for key in codec.keys:
    if key.id == id:
      return some(key)
  none(RouteSigningKey)

proc encodeRoute*(codec: RouteCodec, routeTypeId: uint16, version: uint8,
                  expiresAt: int64, payload: openArray[byte]): string =
  ## Encodes and authenticates a compact URL-safe component `custom_id`.
  ##
  ## Raises `ValueError` for missing cryptographic configuration or when the
  ## encoded value exceeds Discord's 100-byte `custom_id` boundary.
  if codec.signer.isNil:
    raise newException(ValueError, "component route signer is unavailable")
  let key = codec.findKey(codec.activeKeyId)
  if key.isNone:
    raise newException(ValueError, "active component route key is unavailable")

  var framed: seq[byte]
  framed.appendU16(routeTypeId)
  framed.add version
  framed.add codec.activeKeyId
  framed.appendU64(cast[uint64](expiresAt))
  framed.add payload
  let digest = codec.signer(key.get().material, framed)
  for index in 0..<RouteSignatureBytes:
    framed.add digest[index]
  result = "c." & withoutPadding(base64.encode(framed, safe = true))
  if result.len > MaxCustomIdBytes:
    raise newException(ValueError, "encoded component route exceeds 100 bytes")

proc decodeRoute*(codec: RouteCodec, value: string,
                  nowUnixSeconds: int64): RouteDecodeResult =
  ## Authenticates `value` before exposing its route payload.
  if codec.signer.isNil:
    return RouteDecodeResult(ok: false, error: rdeSignerUnavailable)
  if value.len < 3 or value.len > MaxCustomIdBytes or
      not value.startsWith("c."):
    return RouteDecodeResult(ok: false, error: rdeMalformed)
  let encoded = value[2..^1]
  # Reject non-canonical external input before the standard decoder allocates.
  if not encoded.hasBase64UrlShape:
    return RouteDecodeResult(ok: false, error: rdeMalformed)
  var decoded: string
  try:
    decoded = base64.decode(withPadding(encoded))
  except ValueError:
    return RouteDecodeResult(ok: false, error: rdeMalformed)
  if withoutPadding(base64.encode(decoded, safe = true)) != encoded:
    return RouteDecodeResult(ok: false, error: rdeMalformed)
  if decoded.len < RouteHeaderBytes + RouteSignatureBytes:
    return RouteDecodeResult(ok: false, error: rdeMalformed)

  var bytes = newSeq[byte](decoded.len)
  for index, item in decoded:
    bytes[index] = byte(ord(item))
  let keyId = bytes[3]
  let key = codec.findKey(keyId)
  if key.isNone:
    return RouteDecodeResult(ok: false, error: rdeUnknownKey)
  # Authenticate the complete frame before interpreting expiry or payload.
  let signedLength = bytes.len - RouteSignatureBytes
  let digest = codec.signer(key.get().material,
    bytes.toOpenArray(0, signedLength - 1))
  if not constantTimeEqual(
      digest.toOpenArray(0, RouteSignatureBytes - 1),
      bytes.toOpenArray(signedLength, bytes.high)):
    return RouteDecodeResult(ok: false, error: rdeSignatureRejected)

  let expiry = cast[int64](bytes.readU64(4))
  if expiry < nowUnixSeconds:
    return RouteDecodeResult(ok: false, error: rdeExpired)
  RouteDecodeResult(
    ok: true,
    envelope: RouteEnvelope(
      routeTypeId: bytes.readU16(0),
      version: bytes[2],
      keyId: keyId,
      expiresAt: expiry,
      payload: bytes[RouteHeaderBytes..<signedLength]
    )
  )
