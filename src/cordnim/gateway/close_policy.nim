## Reconnect decisions for Discord Gateway close codes.

type
  GatewayCloseCode* = distinct uint16 ## A Gateway WebSocket close code,
    ## including future values.

  ReconnectAction* = enum ## Session action selected after a Gateway disconnect.
    resumeSession, ## Reconnect using the retained session cursor.
    identifyNewSession, ## Discard the cursor and consume an IDENTIFY allowance.
    stopReconnecting ## Treat the close as terminal until configuration changes.

  GatewayCloseDecision* = object ## Classified response to a Gateway close code.
    action*: ReconnectAction ## Session action the supervisor should take.
    retryable*: bool ## Whether reconnecting can succeed without operator
      ## action.
    reason*: string ## Stable diagnostic summary without connection secrets.

func toUint16*(code: GatewayCloseCode): uint16 {.inline, raises: [].} =
  ## Returns the raw WebSocket close code.
  uint16(code)

func classifyGatewayClose*(code: GatewayCloseCode): GatewayCloseDecision {.
    raises: [].} =
  ## Maps known fatal and session-invalidating codes to reconnect behavior.
  ##
  ## Unknown codes conservatively attempt a session resume; Discord can add
  ## transient close codes without requiring a Cordnim release.
  case code.toUint16
  of 4004:
    GatewayCloseDecision(
      action: stopReconnecting,
      reason: "authentication failed",
    )
  of 4010:
    GatewayCloseDecision(action: stopReconnecting, reason: "invalid shard")
  of 4011:
    GatewayCloseDecision(action: stopReconnecting, reason: "sharding required")
  of 4012:
    GatewayCloseDecision(
      action: stopReconnecting,
      reason: "invalid API version",
    )
  of 4013:
    GatewayCloseDecision(action: stopReconnecting, reason: "invalid intents")
  of 4014:
    GatewayCloseDecision(action: stopReconnecting, reason: "disallowed intents")
  of 4007:
    GatewayCloseDecision(
      action: identifyNewSession,
      retryable: true,
      reason: "invalid sequence",
    )
  of 4009:
    GatewayCloseDecision(
      action: identifyNewSession,
      retryable: true,
      reason: "session timed out",
    )
  else:
    GatewayCloseDecision(
      action: resumeSession,
      retryable: true,
      reason: "gateway connection closed",
    )
