## Transport-neutral structured logging contracts with redaction-safe helpers.
##
## Cordnim does not choose an output backend. Applications inject a
## `LogRecorder` and adapt each event to Chronicles, OpenTelemetry, journald,
## or another sink. Runtime code emits stable event names and structured
## values; it never needs to concatenate an exception message into a log line.

import std/[options, times]

import ../core/[errors, ids, secrets]

type
  LogLevel* = enum ## Severity independent of any logging backend.
    llTrace, ## Detailed diagnostics normally disabled in production.
    llDebug, ## Debug information safe to retain when enabled.
    llInfo, ## Expected lifecycle or protocol progress.
    llNotice, ## Significant but successful state transition.
    llWarn, ## Recoverable failure or degraded behavior.
    llError, ## Operation failed and requires attention.
    llFatal ## Runtime cannot continue safely.

  LogValueKind* = enum ## JSON-compatible structured value category.
    lvString, ## Already-redacted UTF-8 text.
    lvInteger, ## Signed integral value.
    lvFloat, ## Floating-point value.
    lvBoolean ## Boolean value.

  LogValue* = object ## One typed, backend-neutral structured value.
    case kind*: LogValueKind ## Active value representation.
    of lvString:
      stringValue*: string ## Text safe for operator-visible output.
    of lvInteger:
      integerValue*: int64 ## Signed integer value.
    of lvFloat:
      floatValue*: float64 ## Floating-point value.
    of lvBoolean:
      booleanValue*: bool ## Boolean value.

  LogAttribute* = object ## Named structured field attached to one event.
    key*: string ## Stable snake-case field name.
    value*: LogValue ## Typed field value.

  LogEvent* = object ## One structured runtime event.
    name*: string ## Stable dotted event name, not a prose message.
    level*: LogLevel ## Backend-neutral severity.
    attributes*: seq[LogAttribute] ## Ordered structured fields.

  LogRecorder* = proc(event: LogEvent) {.closure, gcsafe, raises: [].}
    ## Synchronous non-raising sink for one already-redacted event.
    ##
    ## A recorder must enqueue or write quickly. It owns aggregation, output,
    ## and backend filtering; Cordnim retains no event after this call.

func logValue*(value: string): LogValue {.raises: [].} =
  ## Wraps text that the caller has already classified as safe to log.
  LogValue(kind: lvString, stringValue: value)

func logValue*(value: int64): LogValue {.raises: [].} =
  ## Wraps a signed integer.
  LogValue(kind: lvInteger, integerValue: value)

func logValue*(value: int): LogValue {.raises: [].} =
  ## Wraps a platform integer after lossless widening.
  logValue(int64(value))

func logValue*(value: float64): LogValue {.raises: [].} =
  ## Wraps a floating-point value.
  LogValue(kind: lvFloat, floatValue: value)

func logValue*(value: bool): LogValue {.raises: [].} =
  ## Wraps a Boolean value.
  LogValue(kind: lvBoolean, booleanValue: value)

func logValue*[SecretKind](value: Secret[SecretKind]): LogValue
    {.raises: [].} =
  ## Wraps a secret as Cordnim's fixed redaction marker, never its bytes.
  discard value
  logValue(redactedSecret)

func logAttribute*(key: string; value: string): LogAttribute {.raises: [].} =
  ## Creates one already-redacted text attribute.
  LogAttribute(key: key, value: logValue(value))

func logAttribute*(key: string; value: int64): LogAttribute {.raises: [].} =
  ## Creates one integer attribute.
  LogAttribute(key: key, value: logValue(value))

func logAttribute*(key: string; value: int): LogAttribute {.raises: [].} =
  ## Creates one platform-integer attribute.
  LogAttribute(key: key, value: logValue(value))

func logAttribute*(key: string; value: float64): LogAttribute {.raises: [].} =
  ## Creates one floating-point attribute.
  LogAttribute(key: key, value: logValue(value))

func logAttribute*(key: string; value: bool): LogAttribute {.raises: [].} =
  ## Creates one Boolean attribute.
  LogAttribute(key: key, value: logValue(value))

func logAttribute*[SecretKind](key: string;
                               value: Secret[SecretKind]): LogAttribute
    {.raises: [].} =
  ## Creates an attribute whose secret value is unconditionally redacted.
  LogAttribute(key: key, value: logValue(value))

func logEvent*(name: string; level: LogLevel;
               attributes: openArray[LogAttribute] = []): LogEvent
    {.raises: [].} =
  ## Creates an event and copies its attributes in the supplied order.
  LogEvent(name: name, level: level, attributes: @attributes)

proc record*(recorder: LogRecorder; event: sink LogEvent) {.raises: [].} =
  ## Emits exactly one event; a nil recorder is a no-op.
  if not recorder.isNil:
    recorder(event)

func failureAttributes*(metadata: DiscordFailureMeta): seq[LogAttribute]
    {.raises: [].} =
  ## Converts available Discord failure metadata to structured fields.
  ##
  ## The `route` member is safe only because `DiscordFailureMeta` requires a
  ## sanitized route or operation identifier; callers must never place a raw
  ## webhook URL or token-bearing query string there.
  if metadata.status.isSome:
    result.add logAttribute("http_status", metadata.status.get)
  if metadata.discordCode.isSome:
    result.add logAttribute("discord_code", metadata.discordCode.get)
  if metadata.route.isSome:
    result.add logAttribute("route", metadata.route.get)
  if metadata.bucket.isSome:
    result.add logAttribute("bucket", metadata.bucket.get)
  if metadata.retryAfter.isSome:
    result.add logAttribute(
      "retry_after_ms", metadata.retryAfter.get.inMilliseconds)
  if metadata.requestId.isSome:
    result.add logAttribute("request_id", metadata.requestId.get)
  if metadata.shardId.isSome:
    result.add logAttribute("shard_id", metadata.shardId.get)
  if metadata.interactionId.isSome:
    result.add logAttribute(
      "interaction_id", $metadata.interactionId.get)

func discordFailureEvent*(eventName: string; level: LogLevel;
                          error: ref DiscordError;
                          attributes: openArray[LogAttribute] = []): LogEvent
    {.raises: [].} =
  ## Creates a redaction-safe event for a typed Discord failure.
  ##
  ## The exception message is deliberately omitted: transport or decoder
  ## messages may contain response fragments, URLs, or application data. The
  ## stable error category and structured metadata remain available to sinks.
  result = logEvent(eventName, level)
  result.attributes.add logAttribute("error_kind", error.kind.name)
  if not error.isNil:
    result.attributes.add error.metadata.failureAttributes
  result.attributes.add attributes
