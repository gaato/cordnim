## REST completion sink for automatically deferred interaction webhooks.

import std/json

import chronos

import cordnim/commands
import cordnim/raw/request as raw_request
import cordnim/raw/route as raw_route
import cordnim/raw/routes/webhooks
import cordnim/rest
import ./router

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
      if interaction.kind != JObject or
          not interaction.hasKey("application_id") or
          not interaction.hasKey("token"):
        raise newException(ValueError,
          "interaction webhook credentials are missing")
      let raw = raw_request.initRawRequest(
        updateOriginalWebhookMessage,
        [
          raw_route.initRawParameter(
            "webhook_id", interaction["application_id"].getStr()),
          raw_route.initRawParameter(
            "webhook_token", interaction["token"].getStr())
        ],
        commandResult.editOriginalPayload()
      )
      var meta = defaultRequestMeta()
      meta.priority = rpForeground
      meta.idempotency = idExplicit
      let response = await client.submit(raw.toRuntimeRequest(meta))
      if response.status < 200 or response.status >= 300:
        raise newException(ValueError,
          "Discord rejected deferred interaction completion")
    {.cast(gcsafe).}:
      return update()
