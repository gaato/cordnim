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
import cordnim/gateway/[dispatch_runtime, session]
import cordnim/interactions/[dispatch_core, dispatcher, responder]
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

proc callbackIdentity(event: DispatchEvent; interaction: JsonNode):
    tuple[id: InteractionId, token: Secret[InteractionToken]] =
  if interaction.isNil or interaction.kind != JObject:
    raise event.interactionRouteError()
  let idNode = interaction{"id"}
  let tokenNode = interaction{"token"}
  if idNode.isNil or idNode.kind != JString or
      tokenNode.isNil or tokenNode.kind != JString or
      tokenNode.getStr().len == 0:
    raise event.interactionRouteError()
  try:
    result.id = parseId(InteractionId, idNode.getStr())
  except ValueError:
    raise event.interactionRouteError()
  result.token = initSecret[InteractionToken](tokenNode.getStr())

proc sendInteractionCallback*(
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
  await client.executeNoContent(raw, meta, auth = darNone)

proc gatewayInteractionHandler*[S](
    interactionDispatcher: InteractionDispatcher[S];
    client: ChronosRestClient;
    next: GatewayDispatchHandler = nil,
): GatewayDispatchHandler =
  ## Routes `INTERACTION_CREATE` and delegates every other dispatch to `next`.
  ##
  ## The dispatcher must belong to an app configured with Gateway interaction
  ## ingress. For compatibility with manually constructed test events whose
  ## receive time is zero, the bridge captures the current monotonic time; real
  ## shard runners always stamp the event before queue admission.
  if client.isNil:
    raise newException(ValueError,
      "Gateway interaction bridge requires a REST client")
  let routeInteraction = interactionDispatcher.asGatewayHandler()

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
      let receivedAt = if event.receivedAtMs == 0:
          monotonicMillis()
        else:
          MonoMillis(event.receivedAtMs)

      proc sender(callback: JsonNode): Future[void] {.
          closure, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          return client.sendInteractionCallback(
            identity.id, identity.token, callback, receivedAt)

      await routeInteraction(interaction, receivedAt, sender)
    {.cast(gcsafe).}:
      return run()
