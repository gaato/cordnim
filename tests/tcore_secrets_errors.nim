import std/[assertions, json, jsonutils, options, times]

import cordnim/core/[errors, ids, secrets]

block secretRedaction:
  let token = initSecret[BotToken]("super-secret-token")
  doAssert token.len == 18
  doAssert not token.isEmpty
  doAssert token.reveal == "super-secret-token"
  doAssert $token == redactedSecret
  doAssert repr(token) == redactedSecret
  doAssert %token == newJString(redactedSecret)
  doAssert token.toJson == newJString(redactedSecret)
  doAssert token == initSecret[BotToken]("super-secret-token")

block secretKindsAreDistinct:
  doAssert not compiles(block:
    let bot = initSecret[BotToken]("token")
    let webhook = initSecret[WebhookToken]("token")
    discard bot == webhook
  )
  doAssert not compiles(block:
    let bot = initSecret[BotToken]("token")
    let bearer = initSecret[OAuthBearerToken]("token")
    discard bot == bearer
  )

block failureMetadata:
  let interactionId = toId[InteractionKind](123'u64)
  let metadata = initDiscordFailureMeta(
    status = some(429),
    discordCode = some(20_028'i64),
    route = some("POST /interactions/:id/:token/callback"),
    bucket = some("bucket-id"),
    retryAfter = some(initDuration(milliseconds = 250)),
    requestId = some("request-id"),
    shardId = some(2),
    interactionId = some(interactionId)
  )

  doAssert metadata.status == some(429)
  doAssert metadata.discordCode == some(20_028'i64)
  doAssert metadata.retryAfter.get == initDuration(milliseconds = 250)
  doAssert metadata.interactionId == some(interactionId)

block typedDiscordErrors:
  let metadata = initDiscordFailureMeta(status = some(429))
  let error = newDiscordError(RateLimitError, "rate limited", metadata)
  doAssert error.msg == "rate limited"
  doAssert error.metadata.status == some(429)

  var caughtAsBase = false
  try:
    raise error
  except DiscordError as caught:
    caughtAsBase = true
    doAssert caught.metadata.status == some(429)
  doAssert caughtAsBase

  doAssert newDiscordError(
    RequestCancelledError, "cancelled").kind == dekRequestCancelled
  doAssert newDiscordError(
    RequestDeadlineError, "expired").kind == dekRequestDeadline
  doAssert newDiscordError(
    LifecycleError, "stopped").kind == dekLifecycle
  doAssert dekRequestCancelled.name == "request_cancelled"
  doAssert dekRequestDeadline.name == "request_deadline"
  doAssert dekLifecycle.name == "lifecycle"
