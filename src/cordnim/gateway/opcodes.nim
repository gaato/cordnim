## Gateway opcode values are represented as an open integer domain.
## Unknown values remain inspectable instead of failing enum conversion.

type GatewayOpcode* = distinct int64 ## Open Gateway opcode retaining future
  ## non-negative wire values.

func `==`*(a, b: GatewayOpcode): bool {.borrow.}
  ## Compares raw opcode values.

const
  gatewayDispatch* = GatewayOpcode(0) ## Server event dispatch.
  gatewayHeartbeat* = GatewayOpcode(1) ## Client or server heartbeat request.
  gatewayIdentify* = GatewayOpcode(2) ## Client session identification.
  gatewayPresenceUpdate* = GatewayOpcode(3) ## Client presence update.
  gatewayVoiceStateUpdate* = GatewayOpcode(4) ## Client voice-state update.
  gatewayResume* = GatewayOpcode(6) ## Client session resume request.
  gatewayReconnect* = GatewayOpcode(7) ## Server reconnect-and-resume request.
  gatewayRequestGuildMembers* = GatewayOpcode(8) ## Client guild-member request.
  gatewayInvalidSession* = GatewayOpcode(9) ## Session invalidation notice.
  gatewayHello* = GatewayOpcode(10) ## Server heartbeat configuration.
  gatewayHeartbeatAck* = GatewayOpcode(11) ## Server heartbeat acknowledgement.
  gatewayRequestSoundboardSounds* = GatewayOpcode(31) ## Soundboard request.
  gatewayRequestChannelInfo* = GatewayOpcode(43) ## Channel-information request.

func toInt64*(opcode: GatewayOpcode): int64 {.inline, raises: [].} =
  ## Returns the raw JSON integer without narrowing future values.
  int64(opcode)

func isKnown*(opcode: GatewayOpcode): bool {.raises: [].} =
  ## Tests whether this Cordnim revision names the opcode.
  case opcode.toInt64()
  of gatewayDispatch.toInt64(), gatewayHeartbeat.toInt64(),
      gatewayIdentify.toInt64(), gatewayPresenceUpdate.toInt64(),
      gatewayVoiceStateUpdate.toInt64(), gatewayResume.toInt64(),
      gatewayReconnect.toInt64(), gatewayRequestGuildMembers.toInt64(),
      gatewayInvalidSession.toInt64(), gatewayHello.toInt64(),
      gatewayHeartbeatAck.toInt64(),
      gatewayRequestSoundboardSounds.toInt64(),
      gatewayRequestChannelInfo.toInt64():
    true
  else:
    false
