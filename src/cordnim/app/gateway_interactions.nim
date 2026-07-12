## Production bridge from Gateway `INTERACTION_CREATE` dispatches to the shared
## interaction dispatcher.
##
## HTTP and Gateway ingress remain separate through transport verification and
## delivery. They converge only at `InteractionDispatcher.dispatch`, so command,
## component, modal, and autocomplete routing has one semantic implementation.

import std/[json, options]

import chronos

import cordnim/api/internal/execute
import cordnim/core/[errors, ids, secrets]
import cordnim/gateway/[dispatch_runtime, session, shard_runner]
import cordnim/interactions/[dispatch_core, responder]
import cordnim/interactions/dispatcher {.all.}
import cordnim/interactions/envelope {.all.}
import cordnim/interactions/webhook_completion {.all.}
import cordnim/raw/request as raw_request
import cordnim/raw/route as raw_route
import cordnim/raw/routes/interactions as interaction_routes
import cordnim/rest/[chronos_driver, request]

type
  GatewayInteractionBridgeError* = object of DecodeError
    ## An `INTERACTION_CREATE` dispatch lacked safe callback routing fields.

proc interactionRouteError(event: DispatchEvent):
    ref GatewayInteractionBridgeError =
  newDiscordError(
    GatewayInteractionBridgeError,
    "Gateway interaction callback routing fields are invalid",
    initDiscordFailureMeta(shardId = some(int(event.shardId.toUint16)))
  )

proc parseCallbackIdentity(interaction: JsonNode):
    Option[tuple[id: InteractionId, applicationId: ApplicationId,
                 token: Secret[InteractionToken]]] =
  ## Extracts the initial-callback identity, or `none` when it is malformed.
  ##
  ## A malformed identity never surfaces its own token: callers translate `none`
  ## into a token-free error or a silent drop.
  if interaction.isNil or interaction.kind != JObject:
    return none(tuple[id: InteractionId, applicationId: ApplicationId,
      token: Secret[InteractionToken]])
  let idNode = interaction{"id"}
  let applicationIdNode = interaction{"application_id"}
  let tokenNode = interaction{"token"}
  if idNode.isNil or idNode.kind != JString or
      applicationIdNode.isNil or applicationIdNode.kind != JString or
      tokenNode.isNil or tokenNode.kind != JString or
      tokenNode.getStr().len == 0:
    return none(tuple[id: InteractionId, applicationId: ApplicationId,
      token: Secret[InteractionToken]])
  var id: InteractionId
  var applicationId: ApplicationId
  try:
    id = parseId(InteractionId, idNode.getStr())
    applicationId = parseId(ApplicationId, applicationIdNode.getStr())
  except ValueError:
    return none(tuple[id: InteractionId, applicationId: ApplicationId,
      token: Secret[InteractionToken]])
  if applicationId.toUint64() == 0:
    return none(tuple[id: InteractionId, applicationId: ApplicationId,
      token: Secret[InteractionToken]])
  some((id: id, applicationId: applicationId,
    token: initSecret[InteractionToken](tokenNode.getStr())))

proc callbackIdentity(event: DispatchEvent; interaction: JsonNode):
    tuple[id: InteractionId, applicationId: ApplicationId,
          token: Secret[InteractionToken]] =
  let identity = parseCallbackIdentity(interaction)
  if identity.isNone:
    raise event.interactionRouteError()
  identity.get()

proc sendInteractionCallback(
    client: ChronosRestClient;
    interactionId: InteractionId;
    token: Secret[InteractionToken];
    callback: JsonNode;
    receivedAt: MonoMillis,
): Future[void] {.async.} =
  ## Sends one initial callback with interaction priority and ACK deadline.
  ##
  ## The token appears only in the rendered transport path. The scheduler key,
  ## checked-error metadata, and retry identity use the generated token-free
  ## route template. Initial callbacks are never retried automatically.
  if client.isNil:
    raise newException(ValueError,
      "Gateway interaction callback requires a REST client")
  if callback.isNil or callback.kind != JObject:
    raise newException(ValueError,
      "Gateway interaction callback must be a JSON object")

  var meta = defaultRequestMeta()
  meta.priority = rpInteractionAck
  meta.idempotency = idNever
  meta.deadline = some(receivedAt +
    (DefaultInteractionAckWindowMs - InitialResponseSendMarginMs))
  let raw = raw_request.initRawRequest(
    interaction_routes.createInteractionResponse,
    [
      raw_route.initRawParameter("interaction_id", $interactionId),
      raw_route.initRawParameter("interaction_token", token.reveal())
    ],
    callback
  )
  await client.executeNoContent(raw, auth = darNone, meta = meta)

proc unsafeGatewayInteractionHandler*[S](
    interactionDispatcher: InteractionDispatcher[S];
    client: ChronosRestClient;
    next: GatewayDispatchHandler = nil,
): GatewayDispatchHandler =
  ## Routes a caller-built raw DispatchEvent and delegates other events to `next`.
  ##
  ## Normal shard runners intercept interactions before DispatchEvent creation and
  ## use `gatewayInteractionSink`. This explicitly unsafe compatibility adapter is
  ## for low-level harnesses that already own credential-bearing event payloads.
  ## The dispatcher must belong to an app configured with Gateway interaction
  ## ingress. For compatibility with manually constructed test events whose
  ## receive time is zero, the bridge captures the current monotonic time; real
  ## shard runners always stamp the event before queue admission.
  if client.isNil:
    raise newException(ValueError,
      "Gateway interaction bridge requires a REST client")
  let postAckFactory = interactionWebhookSenderFactory(client)

  result = proc(event: DispatchEvent): Future[void] {.
      closure, gcsafe, raises: [].} =
    proc run(): Future[void] {.async.} =
      if event.name != "INTERACTION_CREATE":
        if not next.isNil:
          await next(event)
        return

      var interaction: JsonNode
      try:
        interaction = parseJson(event.payload)
      except CatchableError:
        raise event.interactionRouteError()
      let identity = event.callbackIdentity(interaction)
      let callbackToken = identity.token
      let ingress = newInteractionEnvelope(
        interaction, interaction.classify(), identity.id,
        identity.applicationId, identity.token, postAckFactory)
      let receivedAt = if event.receivedAtMs == 0:
          monotonicMillis()
        else:
          MonoMillis(event.receivedAtMs)

      proc sender(callback: JsonNode): Future[void] {.
          closure, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          return client.sendInteractionCallback(
            identity.id, callbackToken, callback, receivedAt)

      await interactionDispatcher.dispatchGatewayEnvelope(
        ingress, receivedAt, sender)
    {.cast(gcsafe).}:
      return run()

proc gatewayInteractionSink*[S](
    interactionDispatcher: InteractionDispatcher[S];
    client: ChronosRestClient,
): GatewayInteractionSink =
  ## Adapts the shared dispatcher to the shard runner's direct interaction sink.
  ##
  ## This is the ownership-moving Gateway ingress: the shard runner hands the raw
  ## `INTERACTION_CREATE` payload here without ever constructing a public
  ## `DispatchEvent`, so the interaction token never enters the general event
  ## feed. The dispatcher forms the credential-owning envelope, and this sink
  ## sends the initial callback with the captured identity. A malformed payload is
  ## dropped without surfacing its token.
  if client.isNil:
    raise newException(ValueError,
      "Gateway interaction sink requires a REST client")
  let postAckFactory = interactionWebhookSenderFactory(client)

  result = proc(interaction: JsonNode; receivedAtMs: int64): Future[void] {.
      gcsafe, raises: [].} =
    proc run(): Future[void] {.async.} =
      let identity = parseCallbackIdentity(interaction)
      if identity.isNone:
        return
      let parsed = identity.get()
      let callbackToken = parsed.token
      let ingress = newInteractionEnvelope(
        interaction, interaction.classify(), parsed.id,
        parsed.applicationId, parsed.token, postAckFactory)
      let receivedAt = if receivedAtMs == 0:
          monotonicMillis()
        else:
          MonoMillis(receivedAtMs)

      proc sender(callback: JsonNode): Future[void] {.
          closure, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          return client.sendInteractionCallback(
            parsed.id, callbackToken, callback, receivedAt)

      await interactionDispatcher.dispatchGatewayEnvelope(
        ingress, receivedAt, sender)
    {.cast(gcsafe).}:
      return run()
