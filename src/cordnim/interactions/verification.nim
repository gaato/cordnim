## HTTP interaction signature, timestamp, and replay validation boundary.
##
## Ed25519 arithmetic is delegated to a vetted provider. cordnim never accepts a
## missing provider and performs all framing checks before invoking it.

import std/[strutils, tables]

const DefaultReplayCacheEntries* = 65_536
  ## Default number of accepted signatures retained inside the replay window.

type
  InteractionVerificationKind* = enum ## Request-verification outcome.
    ivValid,                  ## Signature, timestamp, and replay checks passed.
    ivMalformedTimestamp,     ## Timestamp header is not a signed integer.
    ivTimestampOutsideWindow, ## Timestamp is outside the accepted clock skew.
    ivMalformedSignature,     ## Signature header is not 64-byte hexadecimal.
    ivSignatureRejected,      ## Ed25519 verification rejected the message.
    ivReplay,                 ## Signature was seen or the cache failed closed.
    ivBodyTooLarge,           ## Body exceeds the configured byte limit.
    ivVerifierUnavailable     ## No Ed25519 provider was configured.

  InteractionVerification* = object ## Result of validating an HTTP request.
    kind*: InteractionVerificationKind ## Terminal verification outcome.
    timestamp*: int64 ## Parsed Unix timestamp when parsing succeeded.

  Ed25519Verifier* = proc(publicKey, signature, message: openArray[byte]): bool
    {.gcsafe, raises: [].}
    ## Pluggable detached Ed25519 verification boundary.

  ReplayCache* = object ## Bounded in-memory cache of accepted signatures.
    entries: Table[string, int64]
    maxEntries*: int ## Capacity after which verification fails closed.

  VerificationConfig* = object ## HTTP interaction verification policy.
    publicKey*: array[32, byte] ## Discord application Ed25519 public key.
    allowedSkewSeconds*: int64 ## Maximum timestamp difference from local time.
    maxBodyBytes*: int ## Maximum signed request body length.
    verifier*: Ed25519Verifier ## Required reviewed Ed25519 implementation.

proc initReplayCache*(maxEntries = DefaultReplayCacheEntries): ReplayCache =
  ## Creates an empty bounded replay cache.
  ReplayCache(entries: initTable[string, int64](), maxEntries: maxEntries)

func fromHexNibble(value: char): int =
  case value
  of '0'..'9': ord(value) - ord('0')
  of 'a'..'f': ord(value) - ord('a') + 10
  of 'A'..'F': ord(value) - ord('A') + 10
  else: -1

func decodeSignature(value: string, destination: var array[64, byte]): bool =
  if value.len != destination.len * 2:
    return false
  for index in 0 ..< destination.len:
    let high = fromHexNibble(value[index * 2])
    let low = fromHexNibble(value[index * 2 + 1])
    if high < 0 or low < 0:
      return false
    destination[index] = byte((high shl 4) or low)
  true

proc purgeExpired(cache: var ReplayCache, oldestAllowed: int64) =
  var stale: seq[string]
  for key, timestamp in cache.entries.pairs:
    if timestamp < oldestAllowed:
      stale.add key
  for key in stale:
    cache.entries.del key

func outsideAllowedSkew(timestamp, nowUnixSeconds,
                        allowedSkewSeconds: int64): bool =
  # Compare against saturated bounds instead of subtracting two untrusted
  # signed values. A timestamp at an int64 extreme must be rejected, not turn
  # an HTTP request into an OverflowDefect.
  if allowedSkewSeconds < 0:
    return true
  if timestamp >= nowUnixSeconds:
    if nowUnixSeconds > high(int64) - allowedSkewSeconds:
      return false
    timestamp > nowUnixSeconds + allowedSkewSeconds
  else:
    if nowUnixSeconds < low(int64) + allowedSkewSeconds:
      return false
    timestamp < nowUnixSeconds - allowedSkewSeconds

func oldestAcceptedTimestamp(nowUnixSeconds,
                             allowedSkewSeconds: int64): int64 =
  # The caller has already rejected a negative window.
  if nowUnixSeconds < low(int64) + allowedSkewSeconds:
    low(int64)
  else:
    nowUnixSeconds - allowedSkewSeconds

proc verifyInteractionRequest*(config: VerificationConfig,
                               cache: var ReplayCache,
                               signatureHex, timestampText: string,
                               body: openArray[byte],
                               nowUnixSeconds: int64):
                               InteractionVerification =
  ## Verifies framing, timestamp freshness, Ed25519 signature, and replay state.
  ##
  ## The signature message is the exact timestamp header bytes followed by the
  ## request body. The cache is mutated only after cryptographic verification.
  if body.len > config.maxBodyBytes:
    return InteractionVerification(kind: ivBodyTooLarge)

  var timestamp: int64
  try:
    timestamp = parseBiggestInt(timestampText).int64
  except ValueError:
    return InteractionVerification(kind: ivMalformedTimestamp)

  if timestamp.outsideAllowedSkew(
      nowUnixSeconds, config.allowedSkewSeconds):
    return InteractionVerification(
      kind: ivTimestampOutsideWindow,
      timestamp: timestamp
    )

  var signature: array[64, byte]
  if not signatureHex.decodeSignature(signature):
    return InteractionVerification(kind: ivMalformedSignature, timestamp: timestamp)
  if config.verifier.isNil:
    return InteractionVerification(kind: ivVerifierUnavailable, timestamp: timestamp)

  var message = newSeqOfCap[byte](timestampText.len + body.len)
  for value in timestampText:
    message.add byte(ord(value))
  message.add body
  if not config.verifier(config.publicKey, signature, message):
    return InteractionVerification(kind: ivSignatureRejected, timestamp: timestamp)

  cache.purgeExpired(nowUnixSeconds.oldestAcceptedTimestamp(
    config.allowedSkewSeconds))
  # Hex casing is not authenticated: both forms decode to the same signature.
  # Canonicalizing prevents a replay from bypassing the cache via letter case.
  let signatureKey = signatureHex.toLowerAscii()
  if cache.entries.hasKey(signatureKey):
    return InteractionVerification(kind: ivReplay, timestamp: timestamp)
  if cache.maxEntries <= 0 or cache.entries.len >= cache.maxEntries:
    # A full replay cache fails closed. Purging above gives valid old entries a
    # chance to leave before this boundary is reached.
    return InteractionVerification(kind: ivReplay, timestamp: timestamp)
  cache.entries[signatureKey] = timestamp
  InteractionVerification(kind: ivValid, timestamp: timestamp)
