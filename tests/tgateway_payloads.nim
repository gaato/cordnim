import std/[assertions, json, options]

import cordnim/core/secrets
import cordnim/gateway

block hello_round_trip_preserves_unknown_fields:
  let raw = %*{
    "op": 10,
    "d": {
      "heartbeat_interval": 45_000,
      "future_hello_field": {"enabled": true},
    },
    "future_envelope_field": [1, 2, 3],
  }
  let decoded = decodeGatewayHello(raw)
  doAssert decoded.heartbeatIntervalMs == 45_000
  doAssert decoded.toJson() == raw

block heartbeat_null_and_sequence:
  let empty = decodeGatewayHeartbeat(%*{"op": 1, "d": nil})
  doAssert empty.sequence.isNone
  doAssert empty.toJson() == %*{"op": 1, "d": nil}

  let advanced = decodeGatewayHeartbeat(%*{"op": 1, "d": 42})
  doAssert advanced.sequence.get().toInt64() == 42
  doAssert advanced.toJson() == %*{"op": 1, "d": 42}

block heartbeat_ack_preserves_omitted_data:
  let omitted = decodeGatewayHeartbeatAck(%*{"op": 11, "future": true})
  doAssert not omitted.dataPresent
  doAssert omitted.toJson() == %*{"op": 11, "future": true}

  let explicitNull = decodeGatewayHeartbeatAck(%*{"op": 11, "d": nil})
  doAssert explicitNull.dataPresent
  doAssert explicitNull.toJson() == %*{"op": 11, "d": nil}

block identify_round_trip_and_typed_shard:
  let raw = %*{
    "op": 2,
    "d": {
      "token": "sensitive-token",
      "properties": {
        "os": "linux",
        "browser": "cordnim",
        "device": "cordnim",
        "future_property": 1,
      },
      "compress": true,
      "large_threshold": 250,
      "shard": [1, 4],
      "presence": {"status": "online", "activities": [], "afk": false},
      "intents": 513,
      "future_identify_field": "kept",
    },
    "trace_hint": "kept",
  }
  let decoded = decodeGatewayIdentify(raw)
  doAssert decoded.token.reveal() == "sensitive-token"
  doAssert not decoded.extras.data.hasKey("token")
  doAssert decoded.shard.get().shardId.toUint16() == 1
  doAssert decoded.shard.get().totalShards == 4
  doAssert decoded.toJson() == raw

block identify_constructor_serializes_secret_at_wire_boundary:
  let properties = initGatewayIdentifyProperties(
    "linux",
    "cordnim",
    "cordnim",
  )
  let identify = initGatewayIdentify(
    initSecret[BotToken]("wire-token"),
    properties,
    1,
    shard = some(initGatewayShard(ShardId(0), 2)),
  )
  let encoded = identify.toJson()
  doAssert encoded["op"].getInt() == 2
  doAssert encoded["d"]["token"].getStr() == "wire-token"
  doAssert encoded["d"]["shard"] == %*[0, 2]

block resume_typed_inputs_and_round_trip:
  let raw = %*{
    "op": 6,
    "d": {
      "token": "resume-token",
      "session_id": "session-a",
      "seq": 1337,
      "future_resume_field": false,
    },
    "future": 9,
  }
  let decoded = decodeGatewayResume(raw)
  doAssert decoded.sessionId.toString() == "session-a"
  doAssert decoded.sequence.toInt64() == 1337
  doAssert decoded.toJson() == raw

block dispatch_accepts_unknown_event_name_and_raw_data:
  let raw = %*{
    "op": 0,
    "d": {
      "nested": [1, {"future": true}],
    },
    "s": 88,
    "t": "FUTURE_DISCORD_EVENT",
    "future_envelope_field": "kept",
  }
  let decoded = decodeGatewayPayload(raw)
  doAssert decoded.kind == GatewayPayloadKind.Dispatch
  doAssert decoded.dispatch.eventName.toString() == "FUTURE_DISCORD_EVENT"
  doAssert decoded.dispatch.data == raw["d"]
  doAssert decoded.toJson() == raw

block reconnect_and_invalid_session:
  let reconnect = decodeGatewayReconnect(%*{"op": 7, "d": nil})
  doAssert reconnect.dataPresent
  doAssert reconnect.toJson() == %*{"op": 7, "d": nil}

  let invalid = decodeGatewayInvalidSession(
    %*{"op": 9, "d": true, "future": "kept"},
  )
  doAssert invalid.resumable
  doAssert invalid.toJson() == %*{"op": 9, "d": true, "future": "kept"}

block unsupported_opcode_is_lossless:
  let raw = %*{"op": 65_536, "d": [1, 2], "future": {"a": 1}}
  let decoded = decodeGatewayPayload(raw)
  doAssert decoded.kind == GatewayPayloadKind.Other
  doAssert decoded.other.opcode.toInt64() == 65_536
  doAssert decoded.toJson() == raw

  var inconsistent = decoded
  inconsistent.other.opcode = GatewayOpcode(65_537)
  doAssertRaises GatewayPayloadError:
    discard inconsistent.toJson()

block malformed_payloads_raise_gateway_payload_error:
  doAssertRaises GatewayPayloadError:
    discard decodeGatewayPayload(%*[1, 2, 3])
  doAssertRaises GatewayPayloadError:
    discard decodeGatewayPayload(%*{"d": {}})
  doAssertRaises GatewayPayloadError:
    discard decodeGatewayHello(%*{"op": 1, "d": nil})
  doAssertRaises GatewayPayloadError:
    discard decodeGatewayHello(%*{"op": 10, "d": {"heartbeat_interval": 0}})
  doAssertRaises GatewayPayloadError:
    discard decodeGatewayHeartbeat(%*{"op": 1, "d": "42"})
  doAssertRaises GatewayPayloadError:
    discard decodeGatewayDispatch(%*{"op": 0, "d": {}, "s": 1, "t": 2})
  doAssertRaises GatewayPayloadError:
    discard decodeGatewayInvalidSession(%*{"op": 9, "d": "yes"})
  doAssertRaises GatewayPayloadError:
    discard decodeGatewayReconnect(%*{"op": 7, "d": nil, "s": 1})
  doAssertRaises GatewayPayloadError:
    discard decodeGatewayIdentify(%*{
      "op": 2,
      "d": {
        "token": "token",
        "properties": {"os": "x", "browser": "x", "device": "x"},
        "intents": 1,
        "shard": [2, 2],
      },
    })

block constructors_reject_invalid_typed_inputs:
  doAssertRaises ValueError:
    discard initGatewaySessionId("")
  doAssertRaises ValueError:
    discard initGatewayShard(ShardId(1), 1)
  doAssertRaises ValueError:
    discard initGatewayHeartbeat(some(GatewaySequence(-1)))
  doAssertRaises ValueError:
    discard initGatewayResume(
      initSecret[BotToken]("token"),
      initGatewaySessionId("session"),
      GatewaySequence(-1),
    )
