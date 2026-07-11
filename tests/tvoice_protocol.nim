import std/[assertions, options]

import cordnim/voice/[binary_messages, close_policy, protocol, session]

block voice_opcodes_are_open_and_directional:
  doAssert voiceGatewayVersion == 8
  doAssert voiceDaveMlsWelcome.isBinary
  doAssert voiceDaveMlsWelcome.direction == voiceServerToClient
  doAssert voiceSpeaking.direction == voiceBidirectional
  doAssert not VoiceOpcode(200).isKnown

block binary_voice_messages:
  let message = parseServerBinary([0x12'u8, 0x34, 30, 1, 2, 3])
  doAssert message.sequence.get == 0x1234'u16
  doAssert message.opcode == voiceDaveMlsWelcome
  doAssert message.payload == @[1'u8, 2, 3]
  doAssert encodeClientBinary(voiceDaveMlsKeyPackage, [4'u8, 5]) == @[26'u8, 4, 5]
  doAssertRaises ValueError:
    discard parseServerBinary([1'u8, 2])
  doAssertRaises ValueError:
    discard encodeClientBinary(voiceHeartbeat, [])

block voice_sequence_ack_wraps:
  var session = initVoiceGatewaySession("guild", "session")
  doAssert session.sequenceAck == -1
  session.beginIdentify()
  session.established()
  session.observeSequence(high(uint16))
  doAssert session.heartbeatData(123).sequenceAck == int32(high(uint16))
  session.observeSequence(0)
  doAssert session.resumeData.sequenceAck == 0

block voice_close_policy:
  doAssert classifyVoiceClose(VoiceCloseCode(4015)).action == resumeVoiceSession
  doAssert classifyVoiceClose(VoiceCloseCode(4006)).action == identifyVoiceSession
  doAssert classifyVoiceClose(VoiceCloseCode(4017)).action == stopVoiceReconnect
  doAssert not classifyVoiceClose(VoiceCloseCode(4022)).retryable
