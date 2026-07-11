## Shared Discord failure metadata and catchable error categories.

import std/[options, times]

import ./ids

type
  DiscordFailureMeta* = object ## Protocol context retained at a failure boundary.
    status*: Option[int] ## HTTP status, when an HTTP response was received.
    discordCode*: Option[int64] ## Discord's JSON error code, when present.
    route*: Option[string] ## Sanitized route or operation identifier.
    bucket*: Option[string] ## Server-provided REST rate-limit bucket ID.
    retryAfter*: Option[Duration] ## Delay advertised before a safe retry.
    requestId*: Option[string] ## Request correlation identifier.
    shardId*: Option[int] ## Gateway shard associated with the failure.
    interactionId*: Option[InteractionId] ## Interaction associated with the failure.

  DiscordError* = object of CatchableError ## Base class for recoverable Cordnim failures.
    metadata*: DiscordFailureMeta ## Structured context safe for error handling.

  HttpError* = object of DiscordError ## Discord returned an unsuccessful HTTP response.
  RateLimitError* = object of DiscordError ## A request could not meet its rate-limit contract.
  TransportError* = object of DiscordError ## Network transport failed before a valid response.
  DecodeError* = object of DiscordError ## A protocol payload could not be decoded safely.
  ValidationError* = object of DiscordError ## A locally constructed Discord value was invalid.
  PermissionError* = object of DiscordError ## A permission preflight or Discord check failed.
  InteractionExpiredError* = object of DiscordError ## An interaction response deadline elapsed.
  GatewayProtocolError* = object of DiscordError ## The Gateway stream violated session rules.
  VoiceProtocolError* = object of DiscordError ## Voice or DAVE state violated protocol rules.

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
