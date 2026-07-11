## Typed persistent component routes built on authenticated `custom_id` values.
##
## Applications define compact payload encoders explicitly. The high-level
## codec binds those bytes to one Nim type, one stable route ID, and a set of
## versioned migration decoders, so handlers never split untrusted strings.

import ./[model, routes]

type
  RoutePayloadEncoder*[T] = proc(value: T): seq[byte]
    {.gcsafe, raises: [].} ## Encodes one typed action into a compact
                           ## application-defined payload.

  RoutePayloadDecoder*[T] = proc(payload: openArray[byte]): T
    {.gcsafe, raises: [ValueError].} ## Decodes one authenticated payload
                                     ## version into the current Nim type.

  VersionedRouteDecoder*[T] = object ## Migration decoder retained while an
                                     ## older component may still be live.
    version*: uint8 ## Payload version accepted by `decode`.
    decode*: RoutePayloadDecoder[T] ## Decoder upgrading that version to `T`.

  TypedRouteCodec*[T] = object ## Typed route definition plus its shared
                               ## authenticated envelope codec.
    envelope*: RouteCodec ## HMAC keys and signing provider.
    routeTypeId*: uint16 ## Stable application-assigned type ID.
    activeVersion*: uint8 ## Version emitted for new components.
    encodePayload*: RoutePayloadEncoder[T] ## Active-version payload encoder.
    decoders*: seq[VersionedRouteDecoder[T]] ## Active and migration decoders.

  TypedRouteError* = enum ## Stable reason a typed route could not be recovered.
    treNone, ## No error.
    treEnvelopeRejected, ## HMAC, framing, key, or expiry validation failed.
    treWrongRouteType, ## Valid route belongs to a different handler.
    treUnknownVersion, ## No migration decoder accepts the payload version.
    treInvalidPayload ## Version decoder rejected authenticated bytes.

  TypedRouteDecodeResult*[T] = object ## Result of envelope authentication and
                                      ## typed payload decoding.
    case ok*: bool ## Whether a typed value was recovered.
    of true:
      value*: T ## Recovered current-version action value.
      envelope*: RouteEnvelope ## Verified route metadata.
    of false:
      error*: TypedRouteError ## Typed rejection category.
      envelopeError*: RouteDecodeError ## Lower-level cause when applicable.

proc encode*[T](codec: TypedRouteCodec[T], value: T,
                expiresAt: int64): string =
  ## Encodes a typed action as a signed, expiring Discord `custom_id`.
  ##
  ## Raises `ValueError` if no encoder is configured or the authenticated value
  ## exceeds Discord's 100-byte component identifier limit.
  if codec.encodePayload.isNil:
    raise newException(ValueError,
      "typed component route encoder is unavailable")
  let payload = codec.encodePayload(value)
  codec.envelope.encodeRoute(
    codec.routeTypeId, codec.activeVersion, expiresAt, payload)

proc decode*[T](codec: TypedRouteCodec[T], customId: string,
                nowUnixSeconds: int64): TypedRouteDecodeResult[T] =
  ## Authenticates and decodes one route using active or migration decoders.
  let decoded = codec.envelope.decodeRoute(customId, nowUnixSeconds)
  if not decoded.ok:
    return TypedRouteDecodeResult[T](
      ok: false,
      error: treEnvelopeRejected,
      envelopeError: decoded.error
    )
  codec.decodeVerified(decoded.envelope)

proc decodeVerified*[T](codec: TypedRouteCodec[T],
                        envelope: RouteEnvelope): TypedRouteDecodeResult[T] =
  ## Decodes an envelope already authenticated by a shared component router.
  ##
  ## Callers must obtain `envelope` from `RouteCodec.decodeRoute`; this helper
  ## intentionally performs no cryptographic verification itself.
  if envelope.routeTypeId != codec.routeTypeId:
    return TypedRouteDecodeResult[T](
      ok: false,
      error: treWrongRouteType,
      envelopeError: rdeNone
    )

  for decoder in codec.decoders:
    if decoder.version == envelope.version:
      if decoder.decode.isNil:
        break
      try:
        return TypedRouteDecodeResult[T](
          ok: true,
          value: decoder.decode(envelope.payload),
          envelope: envelope
        )
      except ValueError:
        return TypedRouteDecodeResult[T](
          ok: false,
          error: treInvalidPayload,
          envelopeError: rdeNone
        )

  TypedRouteDecodeResult[T](
    ok: false,
    error: treUnknownVersion,
    envelopeError: rdeNone
  )

proc routedButton*[T](label: string, codec: TypedRouteCodec[T], action: T,
                      expiresAt: int64, disabled = false,
                      style = bsPrimary): ComponentNode =
  ## Creates a button whose callback state is fully recoverable after restart.
  button(label, customId = codec.encode(action, expiresAt),
    disabled = disabled, style = style)
