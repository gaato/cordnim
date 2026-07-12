## Typed, forward-compatible JSON codecs for Discord Gateway v10 envelopes.
##
## This module validates the opcode-specific shape of connection lifecycle
## payloads. It intentionally does not own WebSocket I/O, compression, or
## dispatch-event model decoding.

import std/[json, options, tables]

import cordnim/core/secrets

import ./[opcodes, session]

type
  GatewayPayloadError* = object of ValueError ## Malformed Gateway JSON
    ## payload.

  GatewaySessionId* = distinct string ## Non-empty Gateway session ID used by
    ## Resume.

  GatewayEventName* = distinct string ## Open dispatch event-name domain.

  GatewayShard* = object ## Validated Identify shard pair.
    shardId*: ShardId ## Zero-based shard identifier.
    totalShards*: uint16 ## Positive total number of shards.

  GatewayIdentifyProperties* = object ## Identify client metadata.
    os*: string ## Operating-system name.
    browser*: string ## Library name reported as the browser.
    device*: string ## Library name reported as the device.
    unknownFields*: JsonNode ## Unrecognized connection-property fields.

  GatewayWireExtras* = object ## Unknown fields retained by typed projections.
    envelope*: JsonNode ## Unknown fields from the outer Gateway envelope.
    data*: JsonNode ## Unknown fields from an object-valued `d` field.

  GatewayHelloPayload* = object ## Opcode 10 heartbeat configuration.
    heartbeatIntervalMs*: int64 ## Positive heartbeat interval in milliseconds.
    extras*: GatewayWireExtras ## Forward-compatible unknown fields.

  GatewayHeartbeatPayload* = object ## Opcode 1 dispatch-sequence heartbeat.
    sequence*: Option[GatewaySequence] ## `none` serializes as JSON null.
    extras*: GatewayWireExtras ## Forward-compatible envelope fields.

  GatewayHeartbeatAckPayload* = object ## Opcode 11 heartbeat acknowledgement.
    dataPresent*: bool ## Whether the input explicitly contained `"d": null`.
    extras*: GatewayWireExtras ## Forward-compatible envelope fields.

  GatewayIdentifyPayload* = object ## Opcode 2 client handshake payload.
    token*: Secret[BotToken] ## Bot token, redacted by normal renderers.
    properties*: GatewayIdentifyProperties ## Required client metadata.
    compress*: Option[bool] ## Optional per-payload compression request.
    largeThreshold*: Option[uint16] ## Optional value in the range 50..250.
    shard*: Option[GatewayShard] ## Optional validated shard pair.
    presence*: Option[JsonNode] ## Optional raw initial-presence object.
    intents*: uint64 ## Non-negative Gateway intent bit mask.
    extras*: GatewayWireExtras ## Forward-compatible unknown fields.

  GatewayResumePayload* = object ## Opcode 6 session-resume request.
    token*: Secret[BotToken] ## Bot token, redacted by normal renderers.
    sessionId*: GatewaySessionId ## Session selected for resumption.
    sequence*: GatewaySequence ## Last non-negative dispatch sequence.
    extras*: GatewayWireExtras ## Forward-compatible unknown fields.

  GatewayDispatchPayload* = object ## Opcode 0 envelope with raw event data.
    sequence*: GatewaySequence ## Non-negative sequence used for Resume.
    eventName*: GatewayEventName ## Known or future Discord event name.
    data*: JsonNode ## Complete `d` value for downstream event decoding.
    unknownFields*: JsonNode ## Unknown outer-envelope fields.

  GatewayReconnectPayload* = object ## Opcode 7 reconnect-and-resume request.
    dataPresent*: bool ## Whether the input explicitly contained `"d": null`.
    extras*: GatewayWireExtras ## Forward-compatible envelope fields.

  GatewayInvalidSessionPayload* = object ## Opcode 9 invalid-session notice.
    resumable*: bool ## Server-provided resumption hint.
    extras*: GatewayWireExtras ## Forward-compatible envelope fields.

  GatewayOtherPayload* = object ## Uninterpreted future or unsupported opcode.
    opcode*: GatewayOpcode ## Open opcode value from the wire.
    raw*: JsonNode ## Complete original JSON object.

  GatewayPayloadKind* {.pure.} = enum ## Classification from
    ## `decodeGatewayPayload`.
    Dispatch, ## Opcode 0 dispatch event.
    Heartbeat, ## Opcode 1 heartbeat.
    Identify, ## Opcode 2 identify request.
    Resume, ## Opcode 6 resume request.
    Reconnect, ## Opcode 7 reconnect request.
    InvalidSession, ## Opcode 9 invalid-session notice.
    Hello, ## Opcode 10 connection hello.
    HeartbeatAck, ## Opcode 11 heartbeat acknowledgement.
    Other ## Unsupported or future opcode.

  GatewayPayload* = object ## Lifecycle projection with an open `Other` case.
    case kind*: GatewayPayloadKind ## Selects the typed payload projection.
    of GatewayPayloadKind.Dispatch:
      dispatch*: GatewayDispatchPayload ## Dispatch event projection.
    of GatewayPayloadKind.Heartbeat:
      heartbeat*: GatewayHeartbeatPayload ## Heartbeat projection.
    of GatewayPayloadKind.Identify:
      identify*: GatewayIdentifyPayload ## Identify projection.
    of GatewayPayloadKind.Resume:
      resume*: GatewayResumePayload ## Resume projection.
    of GatewayPayloadKind.Reconnect:
      reconnect*: GatewayReconnectPayload ## Reconnect projection.
    of GatewayPayloadKind.InvalidSession:
      invalidSession*: GatewayInvalidSessionPayload ## Invalid session.
    of GatewayPayloadKind.Hello:
      hello*: GatewayHelloPayload ## Hello projection.
    of GatewayPayloadKind.HeartbeatAck:
      heartbeatAck*: GatewayHeartbeatAckPayload ## Heartbeat acknowledgement.
    of GatewayPayloadKind.Other:
      other*: GatewayOtherPayload ## Lossless unrecognized projection.

func dispatchSummary(payload: GatewayDispatchPayload): string =
  ## Deliberately excludes raw data and unknown fields.
  "GatewayDispatchPayload(event: " & string(payload.eventName) &
    ", sequence: " & $payload.sequence.toInt64() & ")"

func `$`*(payload: GatewayDispatchPayload): string =
  ## Safe diagnostics for a dispatch envelope; never traverses its data.
  payload.dispatchSummary()

func repr*(payload: GatewayDispatchPayload): string =
  ## Safe debug diagnostics for a dispatch envelope.
  payload.dispatchSummary()

proc `%`*(payload: GatewayDispatchPayload): JsonNode =
  ## Serializes safe routing metadata, not the credential-bearing wire value.
  %*{
    "eventName": string(payload.eventName),
    "sequence": payload.sequence.toInt64()
  }

proc toJsonHook*(payload: GatewayDispatchPayload): JsonNode =
  ## Redacts dispatch payloads serialized through std/jsonutils.
  %payload

func `$`*(payload: GatewayPayload): string =
  ## Safe lifecycle diagnostics; raw and unknown payload data stay opaque.
  if payload.kind == GatewayPayloadKind.Dispatch:
    "GatewayPayload(" & $payload.dispatch & ")"
  else:
    "GatewayPayload(kind: " & $payload.kind & ")"

func repr*(payload: GatewayPayload): string =
  ## Safe debug diagnostics for the lifecycle wrapper.
  $payload

proc `%`*(payload: GatewayPayload): JsonNode =
  ## Serializes only the kind and safe dispatch metadata.
  result = %*{"kind": $payload.kind}
  if payload.kind == GatewayPayloadKind.Dispatch:
    result["dispatch"] = %payload.dispatch

proc toJsonHook*(payload: GatewayPayload): JsonNode =
  ## Redacts lifecycle wrappers serialized through std/jsonutils.
  %payload

func `==`*(left, right: GatewaySessionId): bool {.borrow.}
  ## Compares Gateway session identifiers.

func `==`*(left, right: GatewayEventName): bool {.borrow.}
  ## Compares dispatch event names without closing the name domain.

proc fail(path, detail: string) {.noinline, noreturn.} =
  raise newException(GatewayPayloadError, path & ": " & detail)

proc requireObject(node: JsonNode; path: string) =
  if node.isNil or node.kind != JObject:
    fail(path, "expected a JSON object")

proc requiredField(node: JsonNode; name, path: string): JsonNode =
  if not node.hasKey(name):
    fail(path & "." & name, "required field is missing")
  node{name}

proc requireString(node: JsonNode; path: string): string =
  if node.isNil or node.kind != JString:
    fail(path, "expected a string")
  node.getStr()

proc requireBool(node: JsonNode; path: string): bool =
  if node.isNil or node.kind != JBool:
    fail(path, "expected a boolean")
  node.getBool()

proc requireInt(node: JsonNode; path: string): int64 =
  if node.isNil or node.kind != JInt:
    fail(path, "expected an integer")
  int64(node.getBiggestInt())

proc unknownObjectFields(
    node: JsonNode;
    knownNames: openArray[string],
): JsonNode =
  node.requireObject("gateway payload")
  result = newJObject()
  for name, value in node:
    if name notin knownNames:
      result[name] = value.copy()

proc objectFromExtras(extras: JsonNode; path: string): JsonNode =
  if extras.isNil:
    return newJObject()
  extras.requireObject(path)
  extras.copy()

proc removeIfPresent(node: JsonNode; name: string) =
  node.fields.del(name)

proc envelopeOpcode(raw: JsonNode): GatewayOpcode =
  raw.requireObject("gateway payload")
  let number = raw.requiredField("op", "gateway payload")
    .requireInt("gateway payload.op")
  if number < 0:
    fail("gateway payload.op", "opcode must be non-negative")
  GatewayOpcode(number)

proc requireOpcode(raw: JsonNode; expected: GatewayOpcode) =
  let actual = raw.envelopeOpcode()
  if actual != expected:
    fail(
      "gateway payload.op",
      "expected " & $expected.toInt64() & ", got " & $actual.toInt64(),
    )
  if expected != gatewayDispatch:
    # Discord reserves `s` and `t` for dispatches. Lifecycle payloads may omit
    # them or send null, but accepting another type would hide a bad envelope.
    for name in ["s", "t"]:
      if raw.hasKey(name) and
          (raw{name}.isNil or raw{name}.kind != JNull):
        fail("gateway payload." & name, "non-dispatch metadata must be null")

proc requireData(raw: JsonNode): JsonNode =
  raw.requiredField("d", "gateway payload")

proc initGatewaySessionId*(value: sink string): GatewaySessionId =
  ## Validates and wraps a non-empty Gateway session identifier.
  if value.len == 0:
    raise newException(ValueError, "gateway session ID must not be empty")
  GatewaySessionId(value)

func toString*(value: GatewaySessionId): string {.inline, raises: [].} =
  ## Returns a copy of the raw Gateway session identifier.
  string(value)

proc initGatewayEventName*(value: sink string): GatewayEventName =
  ## Validates and wraps an open Discord dispatch event name.
  if value.len == 0:
    raise newException(ValueError, "gateway event name must not be empty")
  GatewayEventName(value)

func toString*(value: GatewayEventName): string {.inline, raises: [].} =
  ## Returns a copy of the raw dispatch event name.
  string(value)

proc initGatewayShard*(
    shardId: ShardId;
    totalShards: uint16,
): GatewayShard =
  ## Creates a shard pair, rejecting zero totals and out-of-range IDs.
  if totalShards == 0:
    raise newException(ValueError, "total shard count must be at least one")
  if shardId.toUint16() >= totalShards:
    raise newException(ValueError, "shard ID must be less than total shards")
  GatewayShard(shardId: shardId, totalShards: totalShards)

proc initGatewayIdentifyProperties*(
    os, browser, device: sink string,
): GatewayIdentifyProperties =
  ## Creates required, non-empty Identify connection properties.
  if os.len == 0 or browser.len == 0 or device.len == 0:
    raise newException(
      ValueError,
      "gateway identify properties must not be empty",
    )
  GatewayIdentifyProperties(
    os: os,
    browser: browser,
    device: device,
    unknownFields: newJObject(),
  )

proc initGatewayHeartbeat*(
    sequence: Option[GatewaySequence],
): GatewayHeartbeatPayload =
  ## Creates a heartbeat and validates a present sequence as non-negative.
  if sequence.isSome and sequence.get().toInt64() < 0:
    raise newException(ValueError, "gateway sequence must not be negative")
  GatewayHeartbeatPayload(
    sequence: sequence,
    extras: GatewayWireExtras(envelope: newJObject()),
  )

proc initGatewayIdentify*(
    token: Secret[BotToken];
    properties: GatewayIdentifyProperties;
    intents: uint64;
    compress = none(bool);
    largeThreshold = none(uint16);
    shard = none(GatewayShard);
    presence = none(JsonNode),
): GatewayIdentifyPayload =
  ## Creates an Identify payload and validates all typed wire constraints.
  if token.isEmpty:
    raise newException(ValueError, "gateway identify token must not be empty")
  if properties.os.len == 0 or properties.browser.len == 0 or
      properties.device.len == 0:
    raise newException(
      ValueError,
      "gateway identify properties must not be empty",
    )
  if intents > uint64(high(int64)):
    raise newException(ValueError, "gateway intents exceed JSON integer range")
  if largeThreshold.isSome and
      largeThreshold.get() notin 50'u16..250'u16:
    raise newException(ValueError, "large threshold must be in 50..250")
  if shard.isSome:
    # A shard pair is valid only when its ID indexes the advertised total.
    discard initGatewayShard(
      shard.get().shardId,
      shard.get().totalShards,
    )
  if presence.isSome and
      (presence.get().isNil or presence.get().kind != JObject):
    raise newException(ValueError, "initial presence must be a JSON object")
  result = GatewayIdentifyPayload(
    token: token,
    properties: properties,
    compress: compress,
    largeThreshold: largeThreshold,
    shard: shard,
    presence: presence,
    intents: intents,
    extras: GatewayWireExtras(
      envelope: newJObject(),
      data: newJObject(),
    ),
  )

proc initGatewayResume*(
    token: Secret[BotToken];
    sessionId: GatewaySessionId;
    sequence: GatewaySequence,
): GatewayResumePayload =
  ## Creates a Resume payload from typed session and sequence inputs.
  if token.isEmpty:
    raise newException(ValueError, "gateway resume token must not be empty")
  if sessionId.toString().len == 0:
    raise newException(ValueError, "gateway session ID must not be empty")
  if sequence.toInt64() < 0:
    raise newException(ValueError, "gateway sequence must not be negative")
  GatewayResumePayload(
    token: token,
    sessionId: sessionId,
    sequence: sequence,
    extras: GatewayWireExtras(
      envelope: newJObject(),
      data: newJObject(),
    ),
  )

proc initGatewayResume*(
    token: Secret[BotToken];
    cursor: ResumeCursor,
): GatewayResumePayload =
  ## Creates a Resume payload from a validated session-store cursor.
  initGatewayResume(
    token,
    initGatewaySessionId(cursor.sessionId),
    cursor.sequence,
  )

proc decodeGatewayHello*(raw: sink JsonNode): GatewayHelloPayload =
  ## Decodes opcode 10, preserving unknown envelope and data fields.
  raw.requireOpcode(gatewayHello)
  let data = raw.requireData()
  data.requireObject("gateway payload.d")
  let interval = data.requiredField(
    "heartbeat_interval",
    "gateway payload.d",
  ).requireInt("gateway payload.d.heartbeat_interval")
  if interval <= 0:
    fail(
      "gateway payload.d.heartbeat_interval",
      "heartbeat interval must be positive",
    )
  GatewayHelloPayload(
    heartbeatIntervalMs: interval,
    extras: GatewayWireExtras(
      envelope: raw.unknownObjectFields(["op", "d"]),
      data: data.unknownObjectFields(["heartbeat_interval"]),
    ),
  )

proc decodeGatewayHeartbeat*(raw: sink JsonNode): GatewayHeartbeatPayload =
  ## Decodes opcode 1, accepting either null or a non-negative sequence.
  raw.requireOpcode(gatewayHeartbeat)
  let data = raw.requireData()
  var sequence = none(GatewaySequence)
  if data.isNil:
    fail("gateway payload.d", "expected null or an integer")
  if data.kind != JNull:
    let number = data.requireInt("gateway payload.d")
    if number < 0:
      fail("gateway payload.d", "gateway sequence must not be negative")
    sequence = some(GatewaySequence(number))
  GatewayHeartbeatPayload(
    sequence: sequence,
    extras: GatewayWireExtras(
      envelope: raw.unknownObjectFields(["op", "d"]),
    ),
  )

proc decodeGatewayHeartbeatAck*(
    raw: sink JsonNode,
): GatewayHeartbeatAckPayload =
  ## Decodes opcode 11, accepting an omitted or null `d` field.
  raw.requireOpcode(gatewayHeartbeatAck)
  let dataPresent = raw.hasKey("d")
  if dataPresent and (raw{"d"}.isNil or raw{"d"}.kind != JNull):
    fail("gateway payload.d", "heartbeat ACK data must be null")
  GatewayHeartbeatAckPayload(
    dataPresent: dataPresent,
    extras: GatewayWireExtras(
      envelope: raw.unknownObjectFields(["op", "d"]),
    ),
  )

proc decodeGatewayIdentify*(raw: sink JsonNode): GatewayIdentifyPayload =
  ## Decodes opcode 2 while keeping token bytes out of unknown-field storage.
  raw.requireOpcode(gatewayIdentify)
  let data = raw.requireData()
  data.requireObject("gateway payload.d")

  let tokenText = data.requiredField("token", "gateway payload.d")
    .requireString("gateway payload.d.token")
  if tokenText.len == 0:
    fail("gateway payload.d.token", "token must not be empty")

  let propertyNode = data.requiredField("properties", "gateway payload.d")
  propertyNode.requireObject("gateway payload.d.properties")
  let os = propertyNode.requiredField(
    "os",
    "gateway payload.d.properties",
  ).requireString("gateway payload.d.properties.os")
  let browser = propertyNode.requiredField(
    "browser",
    "gateway payload.d.properties",
  ).requireString("gateway payload.d.properties.browser")
  let device = propertyNode.requiredField(
    "device",
    "gateway payload.d.properties",
  ).requireString("gateway payload.d.properties.device")
  if os.len == 0 or browser.len == 0 or device.len == 0:
    fail(
      "gateway payload.d.properties",
      "connection properties must not be empty",
    )

  let intentNumber = data.requiredField("intents", "gateway payload.d")
    .requireInt("gateway payload.d.intents")
  if intentNumber < 0:
    fail("gateway payload.d.intents", "intents must not be negative")

  var compress = none(bool)
  if data.hasKey("compress"):
    compress = some(data{"compress"}.requireBool(
      "gateway payload.d.compress",
    ))

  var largeThreshold = none(uint16)
  if data.hasKey("large_threshold"):
    let threshold = data{"large_threshold"}.requireInt(
      "gateway payload.d.large_threshold",
    )
    if threshold notin 50'i64..250'i64:
      fail(
        "gateway payload.d.large_threshold",
        "large threshold must be in 50..250",
      )
    largeThreshold = some(uint16(threshold))

  var shard = none(GatewayShard)
  if data.hasKey("shard"):
    let shardNode = data{"shard"}
    if shardNode.isNil or shardNode.kind != JArray or shardNode.len != 2:
      fail("gateway payload.d.shard", "expected a two-integer array")
    let shardNumber = shardNode[0].requireInt("gateway payload.d.shard[0]")
    let totalNumber = shardNode[1].requireInt("gateway payload.d.shard[1]")
    if shardNumber < 0 or shardNumber > int64(high(uint16)):
      fail("gateway payload.d.shard[0]", "shard ID is out of range")
    if totalNumber <= 0 or totalNumber > int64(high(uint16)):
      fail("gateway payload.d.shard[1]", "shard total is out of range")
    if shardNumber >= totalNumber:
      fail("gateway payload.d.shard", "shard ID must be less than total")
    shard = some(GatewayShard(
      shardId: ShardId(uint16(shardNumber)),
      totalShards: uint16(totalNumber),
    ))

  var presence = none(JsonNode)
  if data.hasKey("presence"):
    if data{"presence"}.isNil or data{"presence"}.kind != JObject:
      fail("gateway payload.d.presence", "expected a JSON object")
    presence = some(data{"presence"}.copy())

  GatewayIdentifyPayload(
    token: initSecret[BotToken](tokenText),
    properties: GatewayIdentifyProperties(
      os: os,
      browser: browser,
      device: device,
      unknownFields: propertyNode.unknownObjectFields(
        ["os", "browser", "device"],
      ),
    ),
    compress: compress,
    largeThreshold: largeThreshold,
    shard: shard,
    presence: presence,
    intents: uint64(intentNumber),
    extras: GatewayWireExtras(
      envelope: raw.unknownObjectFields(["op", "d"]),
      data: data.unknownObjectFields([
        "token",
        "properties",
        "compress",
        "large_threshold",
        "shard",
        "presence",
        "intents",
      ]),
    ),
  )

proc decodeGatewayResume*(raw: sink JsonNode): GatewayResumePayload =
  ## Decodes opcode 6 using typed session and sequence values.
  raw.requireOpcode(gatewayResume)
  let data = raw.requireData()
  data.requireObject("gateway payload.d")
  let tokenText = data.requiredField("token", "gateway payload.d")
    .requireString("gateway payload.d.token")
  if tokenText.len == 0:
    fail("gateway payload.d.token", "token must not be empty")
  let sessionText = data.requiredField("session_id", "gateway payload.d")
    .requireString("gateway payload.d.session_id")
  if sessionText.len == 0:
    fail("gateway payload.d.session_id", "session ID must not be empty")
  let sequence = data.requiredField("seq", "gateway payload.d")
    .requireInt("gateway payload.d.seq")
  if sequence < 0:
    fail("gateway payload.d.seq", "gateway sequence must not be negative")
  GatewayResumePayload(
    token: initSecret[BotToken](tokenText),
    sessionId: GatewaySessionId(sessionText),
    sequence: GatewaySequence(sequence),
    extras: GatewayWireExtras(
      envelope: raw.unknownObjectFields(["op", "d"]),
      data: data.unknownObjectFields(["token", "session_id", "seq"]),
    ),
  )

proc decodeGatewayDispatch*(raw: sink JsonNode): GatewayDispatchPayload =
  ## Decodes an opcode 0 envelope without closing the event-name domain.
  raw.requireOpcode(gatewayDispatch)
  let data = raw.requireData()
  if data.isNil:
    fail("gateway payload.d", "dispatch data must be a JSON value")
  let sequence = raw.requiredField("s", "gateway payload")
    .requireInt("gateway payload.s")
  if sequence < 0:
    fail("gateway payload.s", "gateway sequence must not be negative")
  let eventText = raw.requiredField("t", "gateway payload")
    .requireString("gateway payload.t")
  if eventText.len == 0:
    fail("gateway payload.t", "event name must not be empty")
  GatewayDispatchPayload(
    sequence: GatewaySequence(sequence),
    eventName: GatewayEventName(eventText),
    data: data.copy(),
    unknownFields: raw.unknownObjectFields(["op", "d", "s", "t"]),
  )

proc decodeGatewayReconnect*(raw: sink JsonNode): GatewayReconnectPayload =
  ## Decodes opcode 7, accepting an omitted or null `d` field.
  raw.requireOpcode(gatewayReconnect)
  let dataPresent = raw.hasKey("d")
  if dataPresent and (raw{"d"}.isNil or raw{"d"}.kind != JNull):
    fail("gateway payload.d", "reconnect data must be null")
  GatewayReconnectPayload(
    dataPresent: dataPresent,
    extras: GatewayWireExtras(
      envelope: raw.unknownObjectFields(["op", "d"]),
    ),
  )

proc decodeGatewayInvalidSession*(
    raw: sink JsonNode,
): GatewayInvalidSessionPayload =
  ## Decodes opcode 9 and its required boolean resumption hint.
  raw.requireOpcode(gatewayInvalidSession)
  let resumable = raw.requireData().requireBool("gateway payload.d")
  GatewayInvalidSessionPayload(
    resumable: resumable,
    extras: GatewayWireExtras(
      envelope: raw.unknownObjectFields(["op", "d"]),
    ),
  )

proc toJson*(payload: GatewayHelloPayload): JsonNode =
  ## Encodes opcode 10 while merging retained unknown fields.
  if payload.heartbeatIntervalMs <= 0:
    raise newException(
      GatewayPayloadError,
      "gateway payload.d.heartbeat_interval: interval must be positive",
    )
  result = objectFromExtras(payload.extras.envelope, "hello extras.envelope")
  let data = objectFromExtras(payload.extras.data, "hello extras.data")
  result["op"] = newJInt(gatewayHello.toInt64())
  data["heartbeat_interval"] = newJInt(payload.heartbeatIntervalMs)
  result["d"] = data

proc toJson*(payload: GatewayHeartbeatPayload): JsonNode =
  ## Encodes opcode 1 with an integer or null `d` value.
  result = objectFromExtras(
    payload.extras.envelope,
    "heartbeat extras.envelope",
  )
  result["op"] = newJInt(gatewayHeartbeat.toInt64())
  if payload.sequence.isSome:
    let sequence = payload.sequence.get().toInt64()
    if sequence < 0:
      raise newException(
        GatewayPayloadError,
        "gateway payload.d: sequence must not be negative",
      )
    result["d"] = newJInt(sequence)
  else:
    result["d"] = newJNull()

proc toJson*(payload: GatewayHeartbeatAckPayload): JsonNode =
  ## Encodes opcode 11 and preserves omitted-versus-null `d` syntax.
  result = objectFromExtras(
    payload.extras.envelope,
    "heartbeat ACK extras.envelope",
  )
  result["op"] = newJInt(gatewayHeartbeatAck.toInt64())
  if payload.dataPresent:
    result["d"] = newJNull()
  else:
    # Preserve the wire distinction used by Discord's ACK examples.
    result.removeIfPresent("d")

proc toJson*(payload: GatewayIdentifyPayload): JsonNode =
  ## Encodes opcode 2, revealing the token only at this wire boundary.
  if payload.token.isEmpty:
    raise newException(GatewayPayloadError, "identify token must not be empty")
  if payload.intents > uint64(high(int64)):
    raise newException(
      GatewayPayloadError,
      "gateway intents exceed JSON integer range",
    )
  result = objectFromExtras(
    payload.extras.envelope,
    "identify extras.envelope",
  )
  let data = objectFromExtras(payload.extras.data, "identify extras.data")
  let properties = objectFromExtras(
    payload.properties.unknownFields,
    "identify properties unknownFields",
  )
  if payload.properties.os.len == 0 or payload.properties.browser.len == 0 or
      payload.properties.device.len == 0:
    raise newException(
      GatewayPayloadError,
      "gateway identify properties must not be empty",
    )
  properties["os"] = newJString(payload.properties.os)
  properties["browser"] = newJString(payload.properties.browser)
  properties["device"] = newJString(payload.properties.device)
  data["token"] = newJString(payload.token.reveal())
  data["properties"] = properties
  data["intents"] = newJInt(int64(payload.intents))
  if payload.compress.isSome:
    data["compress"] = newJBool(payload.compress.get())
  else:
    data.removeIfPresent("compress")
  if payload.largeThreshold.isSome:
    let threshold = payload.largeThreshold.get()
    if threshold notin 50'u16..250'u16:
      raise newException(
        GatewayPayloadError,
        "large threshold must be in 50..250",
      )
    data["large_threshold"] = newJInt(int64(threshold))
  else:
    data.removeIfPresent("large_threshold")
  if payload.shard.isSome:
    let shard = payload.shard.get()
    if shard.totalShards == 0 or
        shard.shardId.toUint16() >= shard.totalShards:
      raise newException(
        GatewayPayloadError,
        "shard ID must index a positive total shard count",
      )
    data["shard"] = %*[
      shard.shardId.toUint16(),
      shard.totalShards,
    ]
  else:
    data.removeIfPresent("shard")
  if payload.presence.isSome:
    let presence = payload.presence.get()
    if presence.isNil or presence.kind != JObject:
      raise newException(
        GatewayPayloadError,
        "initial presence must be a JSON object",
      )
    data["presence"] = presence.copy()
  else:
    data.removeIfPresent("presence")
  # Secret rendering stays redacted everywhere except this explicit wire
  # serialization point required by Discord's Identify contract.
  result["op"] = newJInt(gatewayIdentify.toInt64())
  result["d"] = data

proc toJson*(payload: GatewayResumePayload): JsonNode =
  ## Encodes opcode 6, revealing the token only at this wire boundary.
  if payload.token.isEmpty:
    raise newException(GatewayPayloadError, "resume token must not be empty")
  if payload.sessionId.toString().len == 0:
    raise newException(GatewayPayloadError, "session ID must not be empty")
  let sequence = payload.sequence.toInt64()
  if sequence < 0:
    raise newException(
      GatewayPayloadError,
      "gateway sequence must not be negative",
    )
  result = objectFromExtras(
    payload.extras.envelope,
    "resume extras.envelope",
  )
  let data = objectFromExtras(payload.extras.data, "resume extras.data")
  data["token"] = newJString(payload.token.reveal())
  data["session_id"] = newJString(payload.sessionId.toString())
  data["seq"] = newJInt(sequence)
  # Resume has the same explicit credential boundary as Identify.
  result["op"] = newJInt(gatewayResume.toInt64())
  result["d"] = data

proc toJson*(payload: GatewayDispatchPayload): JsonNode =
  ## Encodes opcode 0 while retaining raw event data and unknown fields.
  let sequence = payload.sequence.toInt64()
  if sequence < 0:
    raise newException(
      GatewayPayloadError,
      "gateway sequence must not be negative",
    )
  if payload.eventName.toString().len == 0:
    raise newException(GatewayPayloadError, "event name must not be empty")
  if payload.data.isNil:
    raise newException(GatewayPayloadError, "dispatch data must not be nil")
  result = objectFromExtras(
    payload.unknownFields,
    "dispatch unknownFields",
  )
  result["op"] = newJInt(gatewayDispatch.toInt64())
  result["d"] = payload.data.copy()
  result["s"] = newJInt(sequence)
  result["t"] = newJString(payload.eventName.toString())

proc toJson*(payload: GatewayReconnectPayload): JsonNode =
  ## Encodes opcode 7 and preserves omitted-versus-null `d` syntax.
  result = objectFromExtras(
    payload.extras.envelope,
    "reconnect extras.envelope",
  )
  result["op"] = newJInt(gatewayReconnect.toInt64())
  if payload.dataPresent:
    result["d"] = newJNull()
  else:
    result.removeIfPresent("d")

proc toJson*(payload: GatewayInvalidSessionPayload): JsonNode =
  ## Encodes opcode 9 and its resumption hint.
  result = objectFromExtras(
    payload.extras.envelope,
    "invalid session extras.envelope",
  )
  result["op"] = newJInt(gatewayInvalidSession.toInt64())
  result["d"] = newJBool(payload.resumable)

proc decodeGatewayPayload*(raw: sink JsonNode): GatewayPayload =
  ## Decodes lifecycle opcodes and losslessly retains all other envelopes.
  let opcode = raw.envelopeOpcode()
  case opcode.toInt64()
  of gatewayDispatch.toInt64():
    GatewayPayload(
      kind: GatewayPayloadKind.Dispatch,
      dispatch: decodeGatewayDispatch(raw),
    )
  of gatewayHeartbeat.toInt64():
    GatewayPayload(
      kind: GatewayPayloadKind.Heartbeat,
      heartbeat: decodeGatewayHeartbeat(raw),
    )
  of gatewayIdentify.toInt64():
    GatewayPayload(
      kind: GatewayPayloadKind.Identify,
      identify: decodeGatewayIdentify(raw),
    )
  of gatewayResume.toInt64():
    GatewayPayload(
      kind: GatewayPayloadKind.Resume,
      resume: decodeGatewayResume(raw),
    )
  of gatewayReconnect.toInt64():
    GatewayPayload(
      kind: GatewayPayloadKind.Reconnect,
      reconnect: decodeGatewayReconnect(raw),
    )
  of gatewayInvalidSession.toInt64():
    GatewayPayload(
      kind: GatewayPayloadKind.InvalidSession,
      invalidSession: decodeGatewayInvalidSession(raw),
    )
  of gatewayHello.toInt64():
    GatewayPayload(
      kind: GatewayPayloadKind.Hello,
      hello: decodeGatewayHello(raw),
    )
  of gatewayHeartbeatAck.toInt64():
    GatewayPayload(
      kind: GatewayPayloadKind.HeartbeatAck,
      heartbeatAck: decodeGatewayHeartbeatAck(raw),
    )
  else:
    GatewayPayload(
      kind: GatewayPayloadKind.Other,
      other: GatewayOtherPayload(opcode: opcode, raw: raw),
    )

proc toJson*(payload: GatewayPayload): JsonNode =
  ## Encodes a projected payload, preserving its unknown wire data.
  case payload.kind
  of GatewayPayloadKind.Dispatch:
    payload.dispatch.toJson()
  of GatewayPayloadKind.Heartbeat:
    payload.heartbeat.toJson()
  of GatewayPayloadKind.Identify:
    payload.identify.toJson()
  of GatewayPayloadKind.Resume:
    payload.resume.toJson()
  of GatewayPayloadKind.Reconnect:
    payload.reconnect.toJson()
  of GatewayPayloadKind.InvalidSession:
    payload.invalidSession.toJson()
  of GatewayPayloadKind.Hello:
    payload.hello.toJson()
  of GatewayPayloadKind.HeartbeatAck:
    payload.heartbeatAck.toJson()
  of GatewayPayloadKind.Other:
    if payload.other.raw.isNil:
      raise newException(GatewayPayloadError, "other payload raw JSON is nil")
    let rawOpcode = payload.other.raw.envelopeOpcode()
    if rawOpcode != payload.other.opcode:
      raise newException(
        GatewayPayloadError,
        "other payload opcode does not match its raw JSON",
      )
    payload.other.raw.copy()
