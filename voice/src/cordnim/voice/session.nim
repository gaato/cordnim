## Transport-neutral state for Discord Voice Gateway sessions.

import std/options

type
  VoiceGatewayPhase* = enum ## Lifecycle phase of a voice gateway session.
    voiceDisconnected,     ## Session has not started a connection flow.
    voiceIdentifying,      ## Session is identifying a fresh connection.
    voiceEstablished,      ## Session is ready to exchange voice messages.
    voiceResuming,         ## Session is attempting to resume prior state.
    voiceClosed            ## Session is closed.

  VoiceGatewaySession* = object ## Identity and acknowledgement state for a voice session.
    phase*: VoiceGatewayPhase ## Current lifecycle phase.
    serverId*: string ## Guild or call identifier supplied to the Voice Gateway.
    sessionId*: string ## Gateway session identifier used for resumption.
    lastSequence*: Option[uint16] ## Most recently observed server sequence number.

  VoiceHeartbeatData* = object ## Values required by a Voice Gateway v8 heartbeat.
    nonce*: int64 ## Caller-provided heartbeat nonce.
    sequenceAck*: int32 ## Last server sequence, or `-1` before the first message.

  VoiceResumeData* = object ## Values required to resume a voice session.
    serverId*: string ## Guild or call identifier of the session.
    sessionId*: string ## Gateway session identifier to resume.
    sequenceAck*: int32 ## Last server sequence, or `-1` when none was observed.

proc initVoiceGatewaySession*(serverId, sessionId: sink string): VoiceGatewaySession =
  ## Creates a disconnected session with validated identifiers.
  ##
  ## Raises `ValueError` when either identifier is empty.
  if serverId.len == 0:
    raise newException(ValueError, "voice server ID must not be empty")
  if sessionId.len == 0:
    raise newException(ValueError, "voice session ID must not be empty")
  VoiceGatewaySession(
    phase: voiceDisconnected,
    serverId: serverId,
    sessionId: sessionId,
  )

proc beginIdentify*(session: var VoiceGatewaySession) {.raises: [].} =
  ## Marks `session` as identifying a fresh connection.
  session.phase = voiceIdentifying

proc established*(session: var VoiceGatewaySession) {.raises: [].} =
  ## Marks `session` as established and ready for voice traffic.
  session.phase = voiceEstablished

proc beginResume*(session: var VoiceGatewaySession) {.raises: [].} =
  ## Marks `session` as attempting session resumption.
  session.phase = voiceResuming

proc close*(session: var VoiceGatewaySession) {.raises: [].} =
  ## Marks `session` as closed.
  session.phase = voiceClosed

proc observeSequence*(session: var VoiceGatewaySession; sequence: uint16) {.raises: [].} =
  ## Records the sequence of the latest ordered server message.
  # Voice Gateway v8 sequence numbers wrap, so integer monotonicity is invalid.
  session.lastSequence = some(sequence)

func sequenceAck*(session: VoiceGatewaySession): int32 {.raises: [].} =
  ## Returns the last sequence as an acknowledgement, or `-1` when absent.
  if session.lastSequence.isSome:
    int32(session.lastSequence.get)
  else:
    -1'i32

func heartbeatData*(
    session: VoiceGatewaySession;
    nonce: int64,
): VoiceHeartbeatData {.raises: [].} =
  ## Builds heartbeat values from `nonce` and the latest sequence state.
  VoiceHeartbeatData(nonce: nonce, sequenceAck: session.sequenceAck)

func resumeData*(session: VoiceGatewaySession): VoiceResumeData {.raises: [].} =
  ## Builds resumption values from the session identity and sequence state.
  VoiceResumeData(
    serverId: session.serverId,
    sessionId: session.sessionId,
    sequenceAck: session.sequenceAck,
  )
