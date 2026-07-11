## Discord Voice Gateway v8 opcode metadata.

const voiceGatewayVersion* = 8'u8 ## Voice Gateway protocol version implemented here.

type
  VoiceOpcode* = distinct uint8 ## Raw Voice Gateway opcode preserving unknown values.

  VoiceOpcodeDirection* = enum ## Allowed transport direction for an opcode.
    voiceClientToServer,       ## Opcode is sent only by a voice client.
    voiceServerToClient,       ## Opcode is sent only by the voice server.
    voiceBidirectional,        ## Opcode may be sent by either peer.
    voiceDirectionUnknown      ## Opcode has no known direction in this version.

func `==`*(a, b: VoiceOpcode): bool {.borrow.}
  ## Compares opcodes by their numeric wire value.

const
  voiceIdentify* = VoiceOpcode(0) ## Identifies a new voice session.
  voiceSelectProtocol* = VoiceOpcode(1) ## Selects the media transport protocol.
  voiceReady* = VoiceOpcode(2) ## Announces that the voice server is ready.
  voiceHeartbeat* = VoiceOpcode(3) ## Carries a client heartbeat.
  voiceSessionDescription* = VoiceOpcode(4) ## Carries negotiated session parameters.
  voiceSpeaking* = VoiceOpcode(5) ## Updates a participant's speaking state.
  voiceHeartbeatAck* = VoiceOpcode(6) ## Acknowledges a client heartbeat.
  voiceResume* = VoiceOpcode(7) ## Requests voice session resumption.
  voiceHello* = VoiceOpcode(8) ## Announces the heartbeat interval.
  voiceResumed* = VoiceOpcode(9) ## Confirms voice session resumption.
  voiceClientsConnect* = VoiceOpcode(11) ## Announces connected voice clients.
  voiceClientDisconnect* = VoiceOpcode(13) ## Announces a disconnected voice client.
  voiceDavePrepareTransition* = VoiceOpcode(21) ## Begins a DAVE protocol transition.
  voiceDaveExecuteTransition* = VoiceOpcode(22) ## Commits a prepared DAVE transition.
  voiceDaveTransitionReady* = VoiceOpcode(23) ## Reports client readiness for a transition.
  voiceDavePrepareEpoch* = VoiceOpcode(24) ## Begins preparation of a new MLS epoch.
  voiceDaveMlsExternalSender* = VoiceOpcode(25) ## Supplies the MLS external sender package.
  voiceDaveMlsKeyPackage* = VoiceOpcode(26) ## Supplies the client's MLS key package.
  voiceDaveMlsProposals* = VoiceOpcode(27) ## Carries MLS proposals from the server.
  voiceDaveMlsCommitWelcome* = VoiceOpcode(28) ## Carries a client MLS commit and welcome.
  voiceDaveMlsAnnounceCommitTransition* = VoiceOpcode(29) ## Announces an MLS commit transition.
  voiceDaveMlsWelcome* = VoiceOpcode(30) ## Carries an MLS welcome from the server.
  voiceDaveMlsInvalidCommitWelcome* = VoiceOpcode(31) ## Rejects an invalid commit or welcome.

func toUint8*(opcode: VoiceOpcode): uint8 {.inline, raises: [].} =
  ## Returns the opcode's numeric wire value.
  uint8(opcode)

func isKnown*(opcode: VoiceOpcode): bool {.raises: [].} =
  ## Reports whether `opcode` is defined by the supported Voice Gateway version.
  opcode in {
    voiceIdentify,
    voiceSelectProtocol,
    voiceReady,
    voiceHeartbeat,
    voiceSessionDescription,
    voiceSpeaking,
    voiceHeartbeatAck,
    voiceResume,
    voiceHello,
    voiceResumed,
    voiceClientsConnect,
    voiceClientDisconnect,
    voiceDavePrepareTransition,
    voiceDaveExecuteTransition,
    voiceDaveTransitionReady,
    voiceDavePrepareEpoch,
    voiceDaveMlsExternalSender,
    voiceDaveMlsKeyPackage,
    voiceDaveMlsProposals,
    voiceDaveMlsCommitWelcome,
    voiceDaveMlsAnnounceCommitTransition,
    voiceDaveMlsWelcome,
    voiceDaveMlsInvalidCommitWelcome,
  }

func isBinary*(opcode: VoiceOpcode): bool {.raises: [].} =
  ## Reports whether `opcode` uses Voice Gateway v8 binary framing.
  opcode in {
    voiceDaveMlsExternalSender,
    voiceDaveMlsKeyPackage,
    voiceDaveMlsProposals,
    voiceDaveMlsCommitWelcome,
    voiceDaveMlsAnnounceCommitTransition,
    voiceDaveMlsWelcome,
  }

func direction*(opcode: VoiceOpcode): VoiceOpcodeDirection {.raises: [].} =
  ## Returns the permitted sender direction for `opcode`.
  case opcode.toUint8
  of 0, 1, 3, 7, 23, 26, 28, 31:
    voiceClientToServer
  of 2, 4, 6, 8, 9, 11, 13, 21, 22, 24, 25, 27, 29, 30:
    voiceServerToClient
  of 5:
    voiceBidirectional
  else:
    voiceDirectionUnknown
