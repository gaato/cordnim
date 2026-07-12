import std/[json, strutils, unittest]

import chronos

import cordnim/[commands, interactions]
import cordnim/rest

var observedRequests: seq[RawRequest]

func text(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for index, value in bytes:
    result[index] = char(value)

proc recordingWebhookTransport(request: RawRequest):
    Future[TransportResponse] {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    observedRequests.add(request)
  result = newFuture[TransportResponse]("test.webhook.transport")
  result.complete(TransportResponse(status: 200))

proc clearObservedRequests() =
  observedRequests.setLen(0)

proc body(request: RawRequest): JsonNode =
  parseJson(request.body.bodyBytes().text())

suite "interaction webhook responses":
  test "keeps deferred completion compatible":
    clearObservedRequests()
    proc scenario(): Future[void] {.async.} =
      let client = newChronosRestClient(recordingWebhookTransport)
      client.start()
      let sink = interactionWebhookCompletion(client)
      await sink(
        %*{"application_id": "200", "token": "secret-token"},
        succeeded("finished")
      )
      await client.stop()

    waitFor scenario()
    check observedRequests.len == 1
    let request = observedRequests[0]
    check request.route.httpMethod == hmPatch
    check request.urlPath.startsWith("/webhooks/200/")
    check request.urlPath.endsWith("/messages/@original")
    check "secret-token" in request.urlPath
    check request.meta.priority == rpForeground
    check request.meta.idempotency == idExplicit
    check request.body()["content"].getStr() == "finished"
    check request.body()["allowed_mentions"]["parse"].len == 0

  test "edits the original and creates a non-retrying follow-up":
    clearObservedRequests()
    proc scenario(): Future[void] {.async.} =
      let client = newChronosRestClient(recordingWebhookTransport)
      client.start()
      let sender = interactionWebhookSender(
        client,
        %*{"application_id": "200", "token": "secret-token"}
      )
      await sender(ContextResponse(
        action: raEditOriginal,
        visibility: vEphemeral,
        body: %*{"content": "edited", "flags": 4}
      ))
      await sender(ContextResponse(
        action: raFollowup,
        visibility: vEphemeral,
        body: %*{"content": "followup"}
      ))
      await client.stop()

    waitFor scenario()
    check observedRequests.len == 2

    let edit = observedRequests[0]
    check edit.route.httpMethod == hmPatch
    check edit.urlPath.endsWith("/messages/@original")
    check edit.meta.idempotency == idExplicit
    check edit.body()["flags"].getInt() == 68
    check edit.body()["allowed_mentions"]["parse"].len == 0

    let followup = observedRequests[1]
    check followup.route.httpMethod == hmPost
    check followup.urlPath == "/webhooks/200/secret-token"
    check followup.meta.idempotency == idNever
    check followup.meta.retryPolicy.maxAttempts == 1
    check not followup.meta.retryPolicy.retryTransportErrors
    check not followup.meta.retryPolicy.retryServerErrors
    check followup.body()["flags"].getInt() == 64
    check followup.body()["allowed_mentions"]["parse"].len == 0

  test "rejects initial actions before submitting REST":
    clearObservedRequests()
    proc scenario(): Future[void] {.async.} =
      let client = newChronosRestClient(recordingWebhookTransport)
      client.start()
      let sender = interactionWebhookSender(
        client,
        %*{"application_id": "200", "token": "secret-token"}
      )
      try:
        await sender(ContextResponse(
          action: raReply,
          visibility: vPublic,
          body: %*{"content": "too late"}
        ))
      finally:
        await client.stop()

    expect ValueError:
      waitFor scenario()
    check observedRequests.len == 0

  test "validates the client and webhook credentials":
    let client = newChronosRestClient(recordingWebhookTransport)
    expect ValueError:
      discard interactionWebhookSender(
        ChronosRestClient(nil),
        %*{"application_id": "200", "token": "secret-token"}
      )
    expect ValueError:
      discard interactionWebhookSender(client, newJObject())
    expect ValueError:
      discard interactionWebhookSender(
        client,
        %*{"application_id": 200, "token": "secret-token"}
      )
    expect ValueError:
      discard interactionWebhookSender(
        client,
        %*{"application_id": "not-an-id", "token": "secret-token"}
      )
    expect ValueError:
      discard interactionWebhookSender(
        client,
        %*{"application_id": "200", "token": ""}
      )
