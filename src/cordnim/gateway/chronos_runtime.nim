## Production Chronos dependencies for `GatewayShardRunner`.
##
## Low-level runners keep clocks, sleep, jitter, and WebSocket creation
## injectable. These adapters provide the normal production implementation so
## application composition does not need to repeat mechanical closures.

import std/sysrand

import chronos

import cordnim/rest/chronos_driver
import ./[shard_runner, transport, websocket_chronos]

proc chronosGatewayClock*(): int64 {.gcsafe, raises: [].} =
  ## Returns the current Chronos monotonic time in milliseconds.
  int64(monotonicMillis())

proc chronosGatewaySleep*(durationMs: int64): GatewaySleepFuture {.
    gcsafe, raises: [].} =
  ## Sleeps on the Chronos event loop and remains cancellation-transparent.
  sleepAsync(max(0'i64, durationMs).milliseconds)

proc secureGatewayJitter*(spanMs: int64): int64 {.gcsafe, raises: [].} =
  ## Returns operating-system random jitter in `0 .. spanMs`.
  ##
  ## Entropy failure falls back to the midpoint. Jitter spreads work but is not
  ## an authentication primitive, so a safe bounded value is preferable to
  ## failing a live Gateway session.
  if spanMs <= 0:
    return 0
  var bytes: array[8, byte]
  if not urandom(bytes):
    return spanMs div 2
  var value = 0'u64
  for item in bytes:
    value = value shl 8 or uint64(item)
  if spanMs == high(int64):
    return int64(value and uint64(high(int64)))
  int64(value mod uint64(spanMs + 1))

proc chronosGatewayTransportFactory*(
    maxMessageBytes = defaultGatewayMessageBytes,
): GatewayTransportFactory =
  ## Creates a factory that supplies one fresh Chronos WebSocket driver per
  ## connection attempt.
  if maxMessageBytes <= 0:
    raise newException(ValueError,
      "gateway message limit must be positive")
  result = proc(): GatewayTransportDriver {.gcsafe, raises: [].} =
    try:
      newChronosGatewayDriver(maxMessageBytes)
    except ValueError:
      # The positive bound was validated before this closure was created.
      raiseAssert "validated Gateway message limit was rejected"
