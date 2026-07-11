## Reconnection policy for Discord Voice Gateway close codes.

type
  VoiceCloseCode* = distinct uint16 ## Voice Gateway WebSocket close code.

  VoiceReconnectAction* = enum ## Recovery action selected after a voice close.
    resumeVoiceSession, ## Resume the existing voice session.
    identifyVoiceSession, ## Start a fresh voice identification flow.
    stopVoiceReconnect ## Do not reconnect automatically.

  VoiceCloseDecision* = object ## Reconnection policy result for one close code.
    action*: VoiceReconnectAction ## Recovery action to take.
    retryable*: bool ## Whether a later connection attempt may succeed.
    reason*: string ## Stable diagnostic description without sensitive data.

func toUint16*(code: VoiceCloseCode): uint16 {.inline, raises: [].} =
  ## Returns the numeric WebSocket close code.
  uint16(code)

func classifyVoiceClose*(code: VoiceCloseCode): VoiceCloseDecision {.
    raises: [].} =
  ## Selects a conservative reconnection action for `code`.
  ##
  ## Unknown codes request a fresh identification and remain retryable.
  case code.toUint16
  of 4006:
    VoiceCloseDecision(
      action: identifyVoiceSession,
      retryable: true,
      reason: "voice session is no longer valid",
    )
  of 4009:
    VoiceCloseDecision(
      action: identifyVoiceSession,
      retryable: true,
      reason: "voice session timed out",
    )
  of 4015:
    VoiceCloseDecision(
      action: resumeVoiceSession,
      retryable: true,
      reason: "voice server crashed",
    )
  of 4014:
    VoiceCloseDecision(
      action: stopVoiceReconnect,
      reason: "client disconnected",
    )
  of 4017:
    VoiceCloseDecision(
      action: stopVoiceReconnect,
      reason: "DAVE protocol required",
    )
  of 4021:
    VoiceCloseDecision(
      action: stopVoiceReconnect,
      reason: "voice rate limit exceeded",
    )
  of 4022:
    VoiceCloseDecision(action: stopVoiceReconnect, reason: "call terminated")
  of 4004:
    VoiceCloseDecision(
      action: stopVoiceReconnect,
      reason: "voice authentication failed",
    )
  else:
    # A new identification avoids reusing session state for an unknown failure.
    VoiceCloseDecision(
      action: identifyVoiceSession,
      retryable: true,
      reason: "voice connection closed",
    )
