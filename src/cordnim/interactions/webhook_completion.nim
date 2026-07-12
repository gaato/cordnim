## Credential-owning REST sender for acknowledged interaction webhooks.
##
## Post-acknowledgement authority is a capability, not a payload. A sender is
## constructed once from the typed application ID and the `Secret[InteractionToken]`
## captured in the ingress envelope; the interaction token is revealed exactly
## once, at construction, and the resulting closure retains only that credential.
## No later mutation of any caller `JsonNode` can redirect an edit-original or
## follow-up request, because the request identity is fixed when the sender is
## built.

import std/json

import chronos

import cordnim/api/internal/execute
import cordnim/app/context as appcontext
import cordnim/core/ids
import cordnim/core/secrets
import cordnim/raw/request as raw_request
import cordnim/raw/route as raw_route
import cordnim/raw/routes/webhooks
import cordnim/rest
import ./responder
import ./envelope {.all.}

const
  suppressEmbedsFlag = 1 shl 2
  ephemeralFlag = 1 shl 6
  componentsV2Flag = 1 shl 15
  editableWebhookFlags = suppressEmbedsFlag or componentsV2Flag

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
  var flags = 0
  let hasFlags = result.hasKey("flags")
  if hasFlags and result["flags"].kind != JInt:
    if response.action != raEditOriginal or result["flags"].kind != JNull:
      raise newException(ValueError,
        "interaction webhook message flags must be an integer")

  if hasFlags and result["flags"].kind == JInt:
    flags = result["flags"].getInt()

  case response.action
  of raEditOriginal:
    # Existing-message visibility is immutable. Discord's edit-webhook contract
    # permits only SUPPRESS_EMBEDS and IS_COMPONENTS_V2 in an integer flags value.
    if hasFlags and result["flags"].kind == JInt and
        (flags and not editableWebhookFlags) != 0:
      raise newException(ValueError,
        "interaction original-message edit contains unsupported flags")
  of raFollowup:
    if response.visibility == vEphemeral:
      result["flags"] = %(flags or ephemeralFlag)
  else:
    discard

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

proc buildWebhookSender(client: ChronosRestClient, applicationIdText: string,
                        tokenText: string): appcontext.ContextResponseSender {.
                        raises: [].} =
  ## Builds the retained sender closure over already-captured credentials.
  ##
  ## Both credentials are plain strings captured by value: nothing the sender
  ## closes over aliases a caller-owned `JsonNode`, so a later mutation of the
  ## original interaction can never change `webhook_id` or `webhook_token`.
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
          raw_route.initRawParameter("webhook_id", applicationIdText),
          raw_route.initRawParameter("webhook_token", tokenText)
        ],
        response.messageBody()
      )
      discard await client.executeDocument(
        raw, response.action.requestMeta(), auth = darNone,
        statuses = {SuccessStatus(200)})
    {.cast(gcsafe).}:
      return send()

proc interactionWebhookSender(client: ChronosRestClient,
                               applicationId: ApplicationId,
                               token: Secret[InteractionToken]):
                               appcontext.ContextResponseSender {.used.} =
  ## Creates post-acknowledgement response I/O for one interaction credential.
  ##
  ## The interaction token is revealed exactly once here and captured by value.
  ## Original-response edits use PATCH and follow-ups use non-retrying POST;
  ## initial response actions belong to ingress and fail with `ValueError`.
  if client.isNil:
    raise newException(ValueError,
      "interaction webhook sender requires a REST client")
  if applicationId.toUint64() == 0:
    raise newException(ValueError,
      "interaction webhook sender requires a non-zero application ID")
  if token.isEmpty:
    raise newException(ValueError,
      "interaction webhook sender requires a non-empty token")
  buildWebhookSender(client, $applicationId, token.reveal())

proc interactionWebhookSenderFactory(client: ChronosRestClient):
                                      InteractionSenderFactory {.used.} =
  ## Returns an envelope sender factory bound to one REST client.
  ##
  ## The dispatcher passes this to the ingress envelope; the envelope invokes it
  ## once per interaction with the credentials it captured, so credential
  ## ownership stays inside the envelope and never reaches an application handler.
  if client.isNil:
    raise newException(ValueError,
      "interaction webhook sender factory requires a REST client")
  result = proc(applicationId: ApplicationId,
                token: Secret[InteractionToken]): appcontext.ContextResponseSender
                {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      # The client is validated non-nil above; the envelope guarantees a
      # non-empty token and a parsed application ID before this runs.
      return buildWebhookSender(client, $applicationId, token.reveal())
