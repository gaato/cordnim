## Tests for the semantic webhook REST slice.
##
## A capturing probe inspects rendered routes, query strings, JSON bodies, and
## idempotency modes. A `ScriptedRestTransport` with the webhook token
## registered as a secret proves the token is rendered only into the raw path
## and never leaks into a redacted observation, header, or body.

import std/[json, options, strutils, unittest]

import chronos

import cordnim/api/webhooks
import cordnim/core/secrets
import cordnim/rest
import cordnim/testing

const secretToken = "tok-abcDEF-123456"

type CaptureProbe = ref object
  requests: seq[RawRequest]
  responses: seq[TransportResponse]
  cursor: int

proc asTransport(probe: CaptureProbe): RestTransport =
  result = proc(request: RawRequest): Future[TransportResponse] {.
      gcsafe, raises: [].} =
    let expectedAuth =
      if request.route.templatePath.contains("{webhook_token}"):
        darNone
      else:
        darBot
    doAssert request.authRequirement == expectedAuth
    probe.requests.add(request)
    let response =
      if probe.cursor < probe.responses.len: probe.responses[probe.cursor]
      elif probe.responses.len != 0: probe.responses[^1]
      else: TransportResponse(status: 204)
    inc probe.cursor
    result = newFuture[TransportResponse]("test.api.webhooks")
    result.complete(response)

proc startedClient(probe: CaptureProbe): ChronosRestClient =
  result = newChronosRestClient(probe.asTransport())
  result.start()

proc bytesText(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for index, value in bytes:
    result[index] = char(value)

proc bodyJson(request: RawRequest): JsonNode =
  parseJson(request.body.bodyBytes().bytesText())

proc userJson(): JsonNode =
  %*{
    "id": "2", "username": "cord", "avatar": nil, "discriminator": "0",
    "public_flags": 0, "flags": 0, "global_name": nil, "primary_guild": nil,
  }

proc messageJson(): JsonNode =
  %*{
    "id": "100", "channel_id": "42", "author": userJson(), "content": "hi",
    "timestamp": "2026-07-12T00:00:00Z", "edited_timestamp": nil,
    "tts": false, "mention_everyone": false, "mentions": [], "mention_roles": [],
    "attachments": [], "embeds": [], "pinned": false, "type": 0, "flags": 0,
    "components": [],
  }

proc webhookJson(): JsonNode =
  %*{
    "id": "77", "type": 1, "channel_id": "42", "name": "hook", "avatar": nil,
    "application_id": nil, "token": secretToken,
  }

let webhookId = WebhookId.parseId("77")
let channelId = ChannelId.parseId("42")
let guildId = GuildId.parseId("9")
let messageId = MessageId.parseId("100")

proc endpoint(): WebhookEndpoint =
  webhookEndpoint(webhookId, secretToken)

suite "webhook endpoint secrecy":
  test "endpoint display, repr, and JSON never render the token":
    let point = endpoint()
    check point.webhookId == webhookId
    check secretToken notin $point
    check redactedSecret in $point
    check secretToken notin point.repr
    check secretToken notin $(%point)
    check ($(%point)).contains("77")

  test "empty tokens are rejected at the boundary":
    expect ValueError:
      discard webhookEndpoint(webhookId, "")
    expect ValueError:
      discard webhookEndpoint(webhookId,
        initSecret[WebhookToken](""))

suite "semantic webhook REST":
  test "mode-mismatched webhook edits do not compile":
    let probe = CaptureProbe()
    let client = probe.startedClient()
    let legacy = webhookMessageHandle[Legacy](endpoint(), messageId)
    let v2 = webhookMessageHandle[V2](endpoint(), messageId)
    check not compiles(client.editWebhookMessage(v2, legacyWebhookEdit()))
    check not compiles(client.editWebhookMessage(legacy,
      v2WebhookEdit(@[textDisplay("wrong mode")])))
    waitFor client.stop()

  test "execute-and-wait forces wait, decodes a message, is not retryable":
    let probe = CaptureProbe(responses: @[jsonResponse(200, messageJson())])
    let client = probe.startedClient()
    let message = waitFor client.executeWebhookAndWait(endpoint(),
      legacyExecute(legacyMessage("hi"), username = some("bot")),
      threadId = some(channelId))
    waitFor client.stop()
    check message.id == messageId
    let request = probe.requests[0]
    check request.route.templatePath ==
      "/webhooks/{webhook_id}/{webhook_token}"
    check request.urlPath.contains("wait=true")
    check request.urlPath.contains("thread_id=42")
    check request.meta.idempotency == idNever
    let body = request.bodyJson()
    check body["content"].getStr() == "hi"
    check body["username"].getStr() == "bot"
    check body["allowed_mentions"] == %*{"parse": []}
    # The token is rendered only into the raw path, and the scheduler's
    # canonical route identity collapses it under the webhook id.
    check request.urlPath.contains(secretToken)
    check secretToken notin request.route.canonical
    check request.route.canonical.contains("webhook_id=77")

  test "no-wait trigger omits wait and accepts an empty body":
    let probe = CaptureProbe(responses: @[TransportResponse(status: 204)])
    let client = probe.startedClient()
    waitFor client.triggerWebhook(endpoint(),
      legacyExecute(legacyMessage("ping")))
    waitFor client.stop()
    let request = probe.requests[0]
    check not request.urlPath.contains("wait=")
    check request.meta.idempotency == idNever

  test "components v2 execute carries the permanent flag":
    let probe = CaptureProbe(responses: @[jsonResponse(200, messageJson())])
    let client = probe.startedClient()
    discard waitFor client.executeWebhookAndWait(endpoint(),
      v2Execute(v2Draft(textDisplay("v2"))))
    waitFor client.stop()
    let body = probe.requests[0].bodyJson()
    check (body["flags"].getInt() and ComponentsV2MessageFlag) != 0
    check not body.hasKey("content")
    check probe.requests[0].urlPath.contains("with_components=true")

  test "components v2 no-wait execution also forces with_components":
    let probe = CaptureProbe(responses: @[TransportResponse(status: 204)])
    let client = probe.startedClient()
    waitFor client.triggerWebhook(endpoint(),
      v2Execute(v2Draft(textDisplay("v2"))))
    waitFor client.stop()
    check probe.requests[0].urlPath.contains("with_components=true")
    check not probe.requests[0].urlPath.contains("wait=")

  test "components v2 rejects an explicit false with_components override":
    let probe = CaptureProbe(responses: @[jsonResponse(200, messageJson())])
    let client = probe.startedClient()
    expect ValueError:
      discard waitFor client.executeWebhookAndWait(endpoint(),
        v2Execute(v2Draft(textDisplay("v2"))),
        withComponents = some(false))
    waitFor client.stop()
    check probe.requests.len == 0

  test "webhook execution rejects empty and overlong legacy payloads":
    let probe = CaptureProbe(responses: @[TransportResponse(status: 204)])
    let client = probe.startedClient()
    expect ValueError:
      waitFor client.triggerWebhook(endpoint(), legacyExecute(legacyMessage()))
    expect ValueError:
      waitFor client.triggerWebhook(endpoint(),
        legacyExecute(legacyMessage(repeat("界",
          MaxMessageContentLength + 1))))
    waitFor client.stop()
    check probe.requests.len == 0

  test "webhook identity and thread fields are validated before transport":
    expect ValueError:
      discard legacyExecute(legacyMessage("hi"), username = some("   "))
    expect ValueError:
      discard legacyExecute(legacyMessage("hi"),
        avatarUrl = some("ftp://example.com/avatar.png"))
    expect ValueError:
      discard legacyExecute(legacyMessage("hi"), threadName = some("  "))
    expect ValueError:
      discard legacyExecute(legacyMessage("hi"),
        username = some(repeat("界", MaxWebhookNameLength + 1)))

    let probe = CaptureProbe(responses: @[jsonResponse(200, messageJson())])
    let client = probe.startedClient()
    expect ValueError:
      discard waitFor client.executeWebhookAndWait(endpoint(),
        legacyExecute(legacyMessage("hi"), threadName = some("new thread")),
        threadId = some(channelId))
    waitFor client.stop()
    check probe.requests.len == 0

  test "forum thread tags are typed, bounded, unique, and serialized":
    let tag = ForumTagId.parseId("5")
    expect ValueError:
      discard legacyExecute(legacyMessage("hi"), appliedTags = @[tag])
    expect ValueError:
      discard legacyExecute(legacyMessage("hi"),
        threadName = some("topic"), appliedTags = @[tag, tag])
    var tooMany: seq[ForumTagId]
    for value in 1..MaxWebhookAppliedTags + 1:
      tooMany.add(ForumTagId.parseId($value))
    expect ValueError:
      discard legacyExecute(legacyMessage("hi"),
        threadName = some("topic"), appliedTags = tooMany)

    let probe = CaptureProbe(responses: @[TransportResponse(status: 204)])
    let client = probe.startedClient()
    waitFor client.triggerWebhook(endpoint(),
      legacyExecute(legacyMessage("hi"), threadName = some("topic"),
        appliedTags = @[tag]))
    waitFor client.stop()
    let body = probe.requests[0].bodyJson()
    check body["thread_name"].getStr() == "topic"
    check body["applied_tags"] == %*["5"]

  test "legacy webhook bodies reject Components V2 and unknown flags":
    expect ValueError:
      discard legacyExecute(legacyMessage("hi"),
        flags = some(int64(ComponentsV2MessageFlag)))
    expect ValueError:
      discard legacyWebhookEdit(
        flags = some(int64(ComponentsV2MessageFlag)))
    expect ValueError:
      discard v2Execute(v2Draft(textDisplay("v2")),
        flags = some(1'i64 shl 30))

  test "create is not retryable and validates the name":
    let probe = CaptureProbe(responses: @[jsonResponse(200, webhookJson())])
    let client = probe.startedClient()
    discard waitFor client.createWebhook(channelId, "hook")
    waitFor client.stop()
    check probe.requests[0].meta.idempotency == idNever
    check probe.requests[0].bodyJson()["name"].getStr() == "hook"
    expect ValueError:
      discard waitFor client.createWebhook(channelId, "")
    expect ValueError:
      discard waitFor client.createWebhook(channelId, "Discord helper")

  test "fetch, edit, and delete by id use safe idempotency":
    let probe = CaptureProbe(responses: @[jsonResponse(200, webhookJson()),
      jsonResponse(200, webhookJson()), TransportResponse(status: 204)])
    let client = probe.startedClient()
    discard waitFor client.fetchWebhook(webhookId)
    discard waitFor client.editWebhook(webhookId, name = some("renamed"),
      channelId = editClear(ChannelId))
    waitFor client.deleteWebhook(webhookId)
    waitFor client.stop()
    check probe.requests[0].route.canonical ==
      "GET /webhooks/{webhook_id} #webhook_id=77"
    check probe.requests[0].meta.idempotency == idSafe
    let editBody = probe.requests[1].bodyJson()
    check editBody["name"].getStr() == "renamed"
    check editBody["channel_id"].kind == JNull
    check probe.requests[2].meta.idempotency == idSafe

  test "fetch, edit, and delete by endpoint use the token route":
    let probe = CaptureProbe(responses: @[jsonResponse(200, webhookJson()),
      jsonResponse(200, webhookJson()), TransportResponse(status: 204)])
    let client = probe.startedClient()
    discard waitFor client.fetchWebhook(endpoint())
    discard waitFor client.editWebhook(endpoint(), name = some("via-token"))
    waitFor client.deleteWebhook(endpoint())
    waitFor client.stop()
    for request in probe.requests:
      check request.route.templatePath.contains("{webhook_token}")
      check request.urlPath.contains(secretToken)

  test "channel and guild listings accept a null body":
    let probe = CaptureProbe(responses: @[jsonResponse(200, newJNull()),
      jsonResponse(200, newJArray())])
    let client = probe.startedClient()
    let channelHooks = waitFor client.listChannelWebhooks(channelId)
    let guildHooks = waitFor client.listGuildWebhooks(guildId)
    waitFor client.stop()
    check channelHooks.len == 0
    check guildHooks.len == 0
    check probe.requests[0].meta.idempotency == idSafe
    check probe.requests[1].route.canonical ==
      "GET /guilds/{guild_id}/webhooks #guild_id=9"

  test "webhook message edit preserves omit versus clear":
    let probe = CaptureProbe(responses: @[jsonResponse(200, messageJson()),
      TransportResponse(status: 204)])
    let client = probe.startedClient()
    let handle = webhookMessageHandle[Legacy](endpoint(), messageId)
    discard waitFor client.editWebhookMessage(handle,
      legacyWebhookEdit(content = editClear(string)),
      threadId = some(channelId))
    waitFor client.deleteWebhookMessage(endpoint(), messageId)
    waitFor client.stop()
    let body = probe.requests[0].bodyJson()
    check body["content"].kind == JNull
    check body["allowed_mentions"] == %*{"parse": []}
    check probe.requests[0].urlPath.contains("thread_id=42")
    check probe.requests[0].meta.idempotency == idSafe
    check probe.requests[1].meta.idempotency == idSafe

  test "webhook v2 upgrade resets legacy fields and forces components mode":
    let probe = CaptureProbe(responses: @[jsonResponse(200, messageJson())])
    let client = probe.startedClient()
    let handle = webhookMessageHandle[Legacy](endpoint(), messageId)
    discard waitFor client.upgradeWebhookMessageToV2(handle,
      v2WebhookEdit(@[textDisplay("upgraded")]))
    waitFor client.stop()
    let request = probe.requests[0]
    let body = request.bodyJson()
    check request.urlPath.contains("with_components=true")
    check body["content"].kind == JNull
    check body["embeds"] == newJArray()
    check body["poll"].kind == JNull
    check body["allowed_mentions"] == %*{"parse": []}
    check (body["flags"].getInt() and ComponentsV2MessageFlag) != 0

  test "webhook serialization revalidates mutable component graphs":
    let display = textDisplay("safe at construction")
    let execute = v2Execute(v2Draft(display))
    display.text = ""
    let probe = CaptureProbe(responses: @[TransportResponse(status: 204)])
    let client = probe.startedClient()
    expect ValueError:
      waitFor client.triggerWebhook(endpoint(), execute)
    waitFor client.stop()
    check probe.requests.len == 0

suite "webhook token redaction":
  test "scripted observations hide the token in path, headers, and body":
    let scripted = newScriptedRestTransport(
      defaultRedaction().withSecretValues([secretToken]))
    scripted.expectRequest(jsonResponse(200, messageJson()))
    scripted.expectRequest(transportResponse(204))
    let client = newChronosRestClient(scripted.asRestTransport())
    client.start()
    discard waitFor client.executeWebhookAndWait(endpoint(),
      legacyExecute(legacyMessage("secret-free")))
    waitFor client.deleteWebhook(endpoint())
    waitFor client.stop()
    for observed in scripted.observedRequests():
      check secretToken notin observed.redactedPath
      check observed.redactedPath.contains(redactedSecret)
      for (name, value) in observed.redactedHeaders:
        check secretToken notin value
      check secretToken notin observed.bodyBytes.bytesText()
    scripted.assertSatisfied()
