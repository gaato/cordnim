## Shared Discord failure metadata and catchable error categories.

import std/[options, times]

import ./ids

type
  DiscordErrorKind* = enum ## Stable category used by logs, metrics, and retry
                           ## policy without inspecting exception messages.
    dekHttp, ## Discord returned an unsuccessful HTTP response.
    dekRateLimit, ## A local or remote rate-limit contract failed.
    dekTransport, ## Network transport failed before a valid response.
    dekDecode, ## A protocol payload could not be decoded safely.
    dekValidation, ## A locally constructed Discord value was invalid.
    dekRequestCancelled, ## A REST request was explicitly cancelled.
    dekRequestDeadline, ## A REST request expired before dispatch.
    dekLifecycle, ## A runtime was unavailable or stopped during work.
    dekPermission, ## A permission preflight or Discord check failed.
    dekInteractionExpired, ## An interaction response deadline elapsed.
    dekGatewayProtocol, ## Gateway session or payload rules were violated.
    dekVoiceProtocol, ## Voice or DAVE state rules were violated.
    dekOther ## A future `DiscordError` subtype unknown to this version.

  DiscordFailureMeta* = object ## Protocol context retained at a failure
                               ## boundary.
    status*: Option[int] ## HTTP status, when an HTTP response was received.
    discordCode*: Option[int64] ## Discord's JSON error code, when present.
    route*: Option[string] ## Sanitized route or operation identifier.
    bucket*: Option[string] ## Server-provided REST rate-limit bucket ID.
    retryAfter*: Option[Duration] ## Delay advertised before a safe retry.
    requestId*: Option[string] ## Request correlation identifier.
    shardId*: Option[int] ## Gateway shard associated with the failure.
    interactionId*: Option[InteractionId] ## Interaction associated with the
                                          ## failure.

  DiscordError* = object of CatchableError ## Base class for recoverable
                                           ## Cordnim failures.
    metadata*: DiscordFailureMeta ## Structured context safe for error handling.

  HttpError* = object of DiscordError ## Discord returned an unsuccessful HTTP
                                      ## response.
  RateLimitError* = object of DiscordError ## A request could not meet its
                                           ## rate-limit contract.
  TransportError* = object of DiscordError ## Network transport failed before
                                           ## a valid response.
  DecodeError* = object of DiscordError ## A protocol payload could not be
                                        ## decoded safely.
  ValidationError* = object of DiscordError ## A locally constructed Discord
                                            ## value was invalid.
  RequestCancelledError* = object of DiscordError ## A request was explicitly
                                                  ## cancelled.
  RequestDeadlineError* = object of DiscordError ## A request expired before
                                                 ## dispatch.
  LifecycleError* = object of DiscordError ## A runtime was unavailable or
                                           ## stopped during work.
  PermissionError* = object of DiscordError ## A permission preflight or
                                            ## Discord check failed.
  InteractionExpiredError* = object of DiscordError ## An interaction response
                                                     ## deadline elapsed.
  GatewayProtocolError* = object of DiscordError ## The Gateway stream violated
                                                 ## session rules.
  VoiceProtocolError* = object of DiscordError ## Voice or DAVE state violated
                                               ## protocol rules.

proc initDiscordFailureMeta*(
    status = none(int);
    discordCode = none(int64);
    route = none(string);
    bucket = none(string);
    retryAfter = none(Duration);
    requestId = none(string);
    shardId = none(int);
    interactionId = none(InteractionId)): DiscordFailureMeta =
  ## Collects optional protocol metadata without inventing unavailable values.
  DiscordFailureMeta(
    status: status,
    discordCode: discordCode,
    route: route,
    bucket: bucket,
    retryAfter: retryAfter,
    requestId: requestId,
    shardId: shardId,
    interactionId: interactionId
  )

proc newDiscordError*[E: DiscordError](errorType: typedesc[E];
    message: string;
    metadata = DiscordFailureMeta()): ref E =
  ## Constructs a specific Discord error while retaining common metadata.
  result = newException(E, message)
  result.metadata = metadata

func kind*(error: ref DiscordError): DiscordErrorKind {.raises: [].} =
  ## Classifies an error without exposing its potentially sensitive message.
  ##
  ## `dekOther` preserves forward compatibility for application-defined or
  ## future Cordnim subclasses. A nil reference is also classified as other.
  if error.isNil:
    return dekOther
  if error of HttpError:
    dekHttp
  elif error of RateLimitError:
    dekRateLimit
  elif error of TransportError:
    dekTransport
  elif error of DecodeError:
    dekDecode
  elif error of ValidationError:
    dekValidation
  elif error of RequestCancelledError:
    dekRequestCancelled
  elif error of RequestDeadlineError:
    dekRequestDeadline
  elif error of LifecycleError:
    dekLifecycle
  elif error of PermissionError:
    dekPermission
  elif error of InteractionExpiredError:
    dekInteractionExpired
  elif error of GatewayProtocolError:
    dekGatewayProtocol
  elif error of VoiceProtocolError:
    dekVoiceProtocol
  else:
    dekOther

func name*(kind: DiscordErrorKind): string {.raises: [].} =
  ## Returns the stable snake-case representation used in structured output.
  case kind
  of dekHttp: "http"
  of dekRateLimit: "rate_limit"
  of dekTransport: "transport"
  of dekDecode: "decode"
  of dekValidation: "validation"
  of dekRequestCancelled: "request_cancelled"
  of dekRequestDeadline: "request_deadline"
  of dekLifecycle: "lifecycle"
  of dekPermission: "permission"
  of dekInteractionExpired: "interaction_expired"
  of dekGatewayProtocol: "gateway_protocol"
  of dekVoiceProtocol: "voice_protocol"
  of dekOther: "other"
