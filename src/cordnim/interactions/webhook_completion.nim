## REST response sender for acknowledged interaction webhooks.

import std/json

import chronos

import cordnim/app/context as appcontext
import cordnim/commands
import cordnim/core/ids
import cordnim/raw/request as raw_request
import cordnim/raw/route as raw_route
import cordnim/raw/routes/webhooks
import cordnim/rest
import ./[responder, router]

type
  InteractionWebhookCredentials = object
    applicationId: string
    token: string

func webhookCredentials(interaction: JsonNode):
    InteractionWebhookCredentials =
  if interaction.isNil or interaction.kind != JObject:
    raise newException(ValueError,
      "interaction webhook credentials require an object")

  let applicationId = interaction{"application_id"}
  if applicationId.isNil or applicationId.kind != JString:
    raise newException(ValueError,
      "interaction application_id must be a decimal string")
  try:
    let parsed = parseId(ApplicationId, applicationId.getStr())
    if parsed.toUint64() == 0:
      raise newException(ValueError,
        "Discord application ID must be greater than zero")
    result.applicationId = $parsed
  except ValueError as error:
    raise newException(ValueError,
      "invalid interaction application_id: " & error.msg)

  let token = interaction{"token"}
  if token.isNil or token.kind != JString or token.getStr().len == 0:
    raise newException(ValueError,
      "interaction webhook token must be a non-empty string")
  result.token = token.getStr()

func messageBody(response: appcontext.ContextResponse): JsonNode =
  if response.body.isNil or response.body.kind == JNull:
    result = newJObject()
  elif response.body.kind == JObject:
    result = response.body.copy()
  else:
    raise newException(ValueError,
      "interaction webhook message body must be a JSON object")

  if not result.hasKey("allowed_mentions"):
    result["allowed_mentions"] = %*{"parse": []}
  if response.visibility == vEphemeral:
    var flags = 0
    if result.hasKey("flags"):
      if result["flags"].kind != JInt:
        raise newException(ValueError,
          "interaction webhook message flags must be an integer")
      flags = result["flags"].getInt()
    result["flags"] = %(flags or 64)

func requestMeta(action: appcontext.ResponseAction): RequestMeta =
  result = defaultRequestMeta()
  result.priority = rpForeground
  case action
  of raEditOriginal:
    # Repeating the same PATCH body has the same intended resource state.
    result.idempotency = idExplicit
  of raFollowup:
    # A repeated webhook POST would create a duplicate follow-up message.
    result.idempotency = idNever
    result.retryPolicy.maxAttempts = 1
    result.retryPolicy.retryTransportErrors = false
    result.retryPolicy.retryServerErrors = false
  else:
    discard

proc interactionWebhookSender*(client: ChronosRestClient,
                               interaction: JsonNode):
                               appcontext.ContextResponseSender =
  ## Creates post-acknowledgement response I/O for one interaction token.
  ##
  ## Original-response edits use PATCH and follow-ups use non-retrying POST.
  ## Initial response actions belong to HTTP or Gateway ingress and fail with
  ## `ValueError` at this boundary.
  if client.isNil:
    raise newException(ValueError,
      "interaction webhook sender requires a REST client")
  let credentials = interaction.webhookCredentials()
  result = proc(response: appcontext.ContextResponse): Future[void]
      {.gcsafe, raises: [].} =
    proc send(): Future[void] {.async.} =
      let route =
        case response.action
        of raEditOriginal:
          updateOriginalWebhookMessage
        of raFollowup:
          executeWebhook
        else:
          raise newException(ValueError,
            "initial interaction response requires ingress transport")
      let raw = raw_request.initRawRequest(
        route,
        [
          raw_route.initRawParameter(
            "webhook_id", credentials.applicationId),
          raw_route.initRawParameter("webhook_token", credentials.token)
        ],
        response.messageBody()
      )
      let submitted = await client.submit(
        raw.toRuntimeRequest(response.action.requestMeta()))
      if submitted.status < 200 or submitted.status >= 300:
        raise newException(ValueError,
          "Discord rejected interaction webhook response")
    {.cast(gcsafe).}:
      return send()

proc interactionWebhookPostAckSink*(client: ChronosRestClient):
                                    PostAckResponseSink =
  ## Adapts the per-interaction sender to `CommandRouter` post-ACK dispatch.
  if client.isNil:
    raise newException(ValueError,
      "webhook post-ack sink requires a REST client")
  result = proc(interaction: JsonNode,
                response: appcontext.ContextResponse): Future[void]
                {.gcsafe, raises: [].} =
    proc send(): Future[void] {.async.} =
      let sender = interactionWebhookSender(client, interaction)
      await sender(response)
    {.cast(gcsafe).}:
      return send()

proc interactionWebhookCompletion*(client: ChronosRestClient):
                                   DeferredCompletionSink =
  ## Creates a sink that PATCHes the original interaction response.
  ##
  ## The supplied client may use `newWebhookHttpTransport`; a bot token is not
  ## required because Discord authenticates this endpoint with the interaction
  ## token embedded in its path.
  if client.isNil:
    raise newException(ValueError, "webhook completion requires a REST client")
  result = proc(interaction: JsonNode,
                commandResult: CommandResult): Future[void]
                {.gcsafe, raises: [].} =
    proc update(): Future[void] {.async.} =
      let sender = interactionWebhookSender(client, interaction)
      await sender(appcontext.ContextResponse(
        action: raEditOriginal,
        visibility: vPublic,
        body: commandResult.editOriginalPayload()
      ))
    {.cast(gcsafe).}:
      return update()
