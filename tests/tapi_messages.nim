## Tests for the semantic message REST slice.
##
## A capturing probe records the runtime request the scheduler dispatches, so
## the assertions can inspect rendered routes, query strings, JSON bodies, and
## the idempotency mode each operation supplies. A `ScriptedRestTransport`
## covers the redacted-observation contract for reaction routes.

import std/[json, options, strutils, unicode, unittest]

import chronos

import cordnim/api/messages
import cordnim/rest
import cordnim/testing

type CaptureProbe = ref object
  requests: seq[RawRequest]
  responses: seq[TransportResponse]
  cursor: int

proc asTransport(probe: CaptureProbe): RestTransport =
  result = proc(request: RawRequest): Future[TransportResponse] {.
      gcsafe, raises: [].} =
    doAssert request.authRequirement == darBot
    probe.requests.add(request)
    let response =
      if probe.cursor < probe.responses.len: probe.responses[probe.cursor]
      elif probe.responses.len != 0: probe.responses[^1]
      else: TransportResponse(status: 204)
    inc probe.cursor
    result = newFuture[TransportResponse]("test.api.messages")
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

proc userJson(id = "2"): JsonNode =
  %*{
    "id": id, "username": "cord", "avatar": nil, "discriminator": "0",
    "public_flags": 0, "flags": 0, "global_name": nil, "primary_guild": nil,
  }

proc messageJson(id = "100"): JsonNode =
  %*{
    "id": id, "channel_id": "42", "author": userJson(), "content": "hi",
    "timestamp": "2026-07-12T00:00:00Z", "edited_timestamp": nil,
    "tts": false, "mention_everyone": false, "mentions": [], "mention_roles": [],
    "attachments": [], "embeds": [], "pinned": false, "type": 0, "flags": 0,
    "components": [],
  }

proc messageResponse(id = "100"): TransportResponse =
  jsonResponse(200, messageJson(id))

let channelId = ChannelId.parseId("42")
let messageId = MessageId.parseId("100")
let legacyHandle = messageHandle[Legacy](channelId, messageId)
let v2Handle = messageHandle[V2](channelId, messageId)

suite "semantic message REST":
  test "mode-mismatched message edits do not compile":
    let probe = CaptureProbe()
    let client = probe.startedClient()
    check not compiles(client.editMessage(v2Handle, legacyEdit()))
    check not compiles(client.editMessage(legacyHandle,
      v2Edit(@[textDisplay("wrong mode")])))
    waitFor client.stop()

  test "history query renders one cursor and safe idempotency":
    let probe = CaptureProbe(responses: @[jsonResponse(200, %*[messageJson()])])
    let client = probe.startedClient()
    discard waitFor client.listMessages(channelId,
      initMessageHistoryQuery(before = some(MessageId.parseId("99")),
        limit = some(50)))
    waitFor client.stop()
    let request = probe.requests[0]
    check request.route.canonical ==
      "GET /channels/{channel_id}/messages #channel_id=42"
    check request.urlPath.contains("before=99")
    check request.urlPath.contains("limit=50")
    check request.meta.idempotency == idSafe

  test "history query rejects conflicting cursors and out-of-range limits":
    expect ValueError:
      discard initMessageHistoryQuery(before = some(MessageId.parseId("1")),
        after = some(MessageId.parseId("2")))
    expect ValueError:
      discard initMessageHistoryQuery(limit = some(0))
    expect ValueError:
      discard initMessageHistoryQuery(limit = some(101))

  test "legacy create without an enforced nonce is never retried":
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    discard waitFor client.createMessage(channelId,
      legacyCreate(legacyMessage("hello"), tts = true))
    waitFor client.stop()
    let request = probe.requests[0]
    check request.route.canonical ==
      "POST /channels/{channel_id}/messages #channel_id=42"
    check request.meta.idempotency == idNever
    let body = request.bodyJson()
    check body["content"].getStr() == "hello"
    check body["tts"].getBool()
    check not body.hasKey("nonce")
    check body["allowed_mentions"] == %*{"parse": []}

  test "message listings accept the pinned null-array response":
    let probe = CaptureProbe(responses: @[jsonResponse(200, newJNull())])
    let client = probe.startedClient()
    let messages = waitFor client.listMessages(channelId)
    waitFor client.stop()
    check messages.len == 0

  test "legacy create with an enforced nonce becomes nonce-idempotent":
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    discard waitFor client.createMessage(channelId,
      legacyCreate(legacyMessage("hi"),
        nonce = some(stringNonce("abc-123")), enforceNonce = true))
    waitFor client.stop()
    let request = probe.requests[0]
    check request.meta.idempotency == idWithNonce
    let body = request.bodyJson()
    check body["nonce"].getStr() == "abc-123"
    check body["enforce_nonce"].getBool()

  test "a nonce with no enforcement stays non-retryable":
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    discard waitFor client.createMessage(channelId,
      legacyCreate(legacyMessage("hi"), nonce = some(integerNonce(7))))
    waitFor client.stop()
    check probe.requests[0].meta.idempotency == idNever

  test "legacy create accepts a typed poll without raw JSON":
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    let poll = initPollCreate("Pick one",
      [textAnswer("a"), textAnswer("b")], durationHours = 24)
    discard waitFor client.createMessage(channelId,
      legacyCreate(legacyMessage(), poll = some(poll)))
    waitFor client.stop()
    let body = probe.requests[0].bodyJson()
    check body["poll"]["question"]["text"].getStr() == "Pick one"
    check body["poll"]["answers"].len == 2

  test "legacy messages serialize only validated action rows":
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    let row = actionRow(button("Continue", customId = "continue"))
    discard waitFor client.createMessage(channelId,
      legacyCreate(legacyMessage(components = @[row])))
    waitFor client.stop()
    let body = probe.requests[0].bodyJson()
    check body["components"].len == 1
    check body["components"][0]["type"].getInt() == 1
    check body["components"][0]["components"][0]["custom_id"].getStr() ==
      "continue"

    expect ValueError:
      discard legacyMessage(components = @[textDisplay("V2 only")]).toJson()

  test "serialization revalidates a component tree mutated after construction":
    let row = actionRow(button("Continue", customId = "continue"))
    let create = legacyCreate(legacyMessage(components = @[row]))
    row.children.add(textDisplay("not legal in an action row"))
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    expect ValueError:
      discard waitFor client.createMessage(channelId, create)
    waitFor client.stop()
    check probe.requests.len == 0

  test "components v2 create carries the permanent flag and no legacy fields":
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    discard waitFor client.createMessage(channelId,
      v2Create(v2Draft(textDisplay("v2 body"))))
    waitFor client.stop()
    let body = probe.requests[0].bodyJson()
    check (body["flags"].getInt() and ComponentsV2MessageFlag) != 0
    check body["components"].len == 1
    for legacy in ["content", "embeds", "poll", "sticker_ids"]:
      check not body.hasKey(legacy)
    check probe.requests[0].meta.idempotency == idNever

  test "edit preserves omit versus clear semantics":
    let probe = CaptureProbe(responses: @[messageResponse(), messageResponse()])
    let client = probe.startedClient()
    discard waitFor client.editMessage(legacyHandle,
      legacyEdit(content = editSet("changed")))
    discard waitFor client.editMessage(legacyHandle,
      legacyEdit(content = editClear(string)))
    waitFor client.stop()
    let setBody = probe.requests[0].bodyJson()
    check setBody["content"].getStr() == "changed"
    let clearBody = probe.requests[1].bodyJson()
    check clearBody["content"].kind == JNull
    check probe.requests[0].meta.idempotency == idSafe

  test "a default edit changes nothing and remains safe":
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    discard waitFor client.editMessage(legacyHandle, legacyEdit())
    waitFor client.stop()
    check probe.requests[0].bodyJson() == %*{
      "allowed_mentions": {"parse": []},
    }

  test "components v2 edit re-emits the components flag":
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    discard waitFor client.editMessage(v2Handle,
      v2Edit(@[textDisplay("edited")]))
    waitFor client.stop()
    let body = probe.requests[0].bodyJson()
    check (body["flags"].getInt() and ComponentsV2MessageFlag) != 0
    check body["components"].len == 1

  test "a legacy-to-v2 upgrade emits every required legacy reset":
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    discard waitFor client.upgradeMessageToV2(legacyHandle,
      v2Edit(@[textDisplay("upgraded")]))
    waitFor client.stop()
    let body = probe.requests[0].bodyJson()
    check body["content"].kind == JNull
    check body["embeds"] == newJArray()
    check body["sticker_ids"] == newJArray()
    check body["poll"].kind == JNull
    check body["allowed_mentions"] == %*{"parse": []}
    check (body["flags"].getInt() and ComponentsV2MessageFlag) != 0

  test "legacy bodies reject the v2 flag and unsupported flag bits":
    expect ValueError:
      discard legacyCreate(legacyMessage("hi"),
        flags = some(int64(ComponentsV2MessageFlag)))
    expect ValueError:
      discard legacyEdit(flags = some(int64(ComponentsV2MessageFlag)))
    expect ValueError:
      discard v2Create(v2Draft(textDisplay("hi")),
        flags = some(1'i64 shl 30))

  test "content and nonce limits count Unicode characters, not bytes":
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    let content = repeat("界", MaxMessageContentLength)
    discard waitFor client.createMessage(channelId,
      legacyCreate(legacyMessage(content)))
    waitFor client.stop()
    check probe.requests[0].bodyJson()["content"].getStr().runeLen ==
      MaxMessageContentLength
    discard stringNonce(repeat("界", MaxNonceLength))
    expect ValueError:
      discard stringNonce(repeat("界", MaxNonceLength + 1))
    expect ValueError:
      discard stringNonce("\xFF")

    let invalidProbe = CaptureProbe(responses: @[messageResponse()])
    let invalidClient = invalidProbe.startedClient()
    expect ValueError:
      discard waitFor invalidClient.createMessage(channelId,
        legacyCreate(legacyMessage(repeat("界",
          MaxMessageContentLength + 1))))
    waitFor invalidClient.stop()
    check invalidProbe.requests.len == 0

  test "empty creates and nonce enforcement without a nonce are rejected":
    expect ValueError:
      discard legacyCreate(legacyMessage(), enforceNonce = true)
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    expect ValueError:
      discard waitFor client.createMessage(channelId,
        legacyCreate(legacyMessage()))
    waitFor client.stop()
    check probe.requests.len == 0

  test "allowed mentions are typed, explicit, and conflict checked":
    let policy = initAllowedMentions(
      userIds = @[UserId.parseId("2")], repliedUser = some(false))
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    discard waitFor client.createMessage(channelId,
      legacyCreate(legacyMessage("hi"), allowedMentions = policy))
    waitFor client.stop()
    let mentions = probe.requests[0].bodyJson()["allowed_mentions"]
    check mentions["parse"] == newJArray()
    check mentions["users"] == %*["2"]
    check not mentions["replied_user"].getBool()
    expect ValueError:
      discard initAllowedMentions(parse = {ampUsers},
        userIds = @[UserId.parseId("2")])

  test "typed forward references require and serialize a source channel":
    expect ValueError:
      discard messageReferenceRequest(messageId, kind = mrForward)
    let reference = messageReferenceRequest(messageId,
      channelId = some(channelId), kind = mrForward)
    let probe = CaptureProbe(responses: @[messageResponse()])
    let client = probe.startedClient()
    discard waitFor client.createMessage(channelId,
      legacyCreate(legacyMessage(), reference = some(reference)))
    waitFor client.stop()
    let body = probe.requests[0].bodyJson()["message_reference"]
    check body["type"].getInt() == ord(mrForward)
    check body["message_id"].getStr() == "100"
    check body["channel_id"].getStr() == "42"

  test "crosspost and bulk delete are not retryable":
    let probe = CaptureProbe(responses: @[messageResponse(),
      TransportResponse(status: 204)])
    let client = probe.startedClient()
    discard waitFor client.crosspostMessage(channelId, messageId)
    waitFor client.bulkDeleteMessages(channelId,
      @[MessageId.parseId("1"), MessageId.parseId("2"), MessageId.parseId("3")])
    waitFor client.stop()
    check probe.requests[0].meta.idempotency == idNever
    check probe.requests[1].meta.idempotency == idNever
    let body = probe.requests[1].bodyJson()
    check body["messages"].len == 3

  test "bulk delete rejects out-of-range counts and duplicate ids":
    let probe = CaptureProbe(responses: @[TransportResponse(status: 204)])
    let client = probe.startedClient()
    expect ValueError:
      waitFor client.bulkDeleteMessages(channelId, @[MessageId.parseId("1")])
    expect ValueError:
      waitFor client.bulkDeleteMessages(channelId,
        @[MessageId.parseId("1"), MessageId.parseId("1")])
    waitFor client.stop()

  test "reactions render encoded emoji paths and safe idempotency":
    let probe = CaptureProbe(responses: @[TransportResponse(status: 204),
      jsonResponse(200, %*[userJson()])])
    let client = probe.startedClient()
    waitFor client.addReaction(channelId, messageId,
      customEmoji("blob", EmojiId.parseId("555")))
    discard waitFor client.listReactions(channelId, messageId,
      unicodeEmoji("🔥"), initReactionQuery(limit = some(10), kind = some(rtBurst)))
    waitFor client.stop()
    check probe.requests[0].route.canonical.contains(
      "PUT /channels/{channel_id}/messages/{message_id}/reactions/{emoji_name}/@me")
    # A custom emoji renders as name:id with the colon percent-encoded.
    check probe.requests[0].urlPath.contains("blob%3A555")
    check probe.requests[0].meta.idempotency == idSafe
    check probe.requests[1].urlPath.contains("type=1")
    check probe.requests[1].urlPath.contains("limit=10")

  test "reaction and nonce validation rejects malformed input":
    expect ValueError:
      discard unicodeEmoji("")
    expect ValueError:
      discard stringNonce(repeat("x", MaxNonceLength + 1))

  test "poll voter listing and expiration use their semantic routes":
    let voters = %*{"users": [userJson()]}
    let probe = CaptureProbe(responses: @[jsonResponse(200, voters),
      messageResponse()])
    let client = probe.startedClient()
    let users = waitFor client.listPollAnswerVoters(channelId, messageId,
      PollAnswerId(2), initPollVoterQuery(after = some(UserId.parseId("1")),
        limit = some(25)))
    discard waitFor client.endPoll(channelId, messageId)
    waitFor client.stop()
    check users.len == 1
    check probe.requests[0].route.templatePath ==
      "/channels/{channel_id}/polls/{message_id}/answers/{answer_id}"
    check probe.requests[0].urlPath.contains("after=1")
    check probe.requests[0].urlPath.contains("limit=25")
    check probe.requests[0].meta.idempotency == idSafe
    check probe.requests[1].route.templatePath ==
      "/channels/{channel_id}/polls/{message_id}/expire"
    check probe.requests[1].meta.idempotency == idNever

  test "current pins decode into typed values":
    let pinsBody = %*{
      "items": [{"pinned_at": "2026-07-12T00:00:00Z", "message": messageJson()}],
      "has_more": false,
    }
    let probe = CaptureProbe(responses: @[jsonResponse(200, pinsBody),
      TransportResponse(status: 204)])
    let client = probe.startedClient()
    let pins = waitFor client.listPins(channelId,
      initPinQuery(limit = some(25)))
    waitFor client.pinMessage(channelId, messageId)
    waitFor client.stop()
    check pins.items.len == 1
    check pins.items[0].message.id == messageId
    check not pins.hasMore
    check probe.requests[0].urlPath.contains("limit=25")
    check probe.requests[1].route.canonical.contains(
      "PUT /channels/{channel_id}/messages/pins/{message_id}")
    check probe.requests[1].meta.idempotency == idSafe

  test "pin pagination rejects timestamps that are not RFC 3339":
    expect ValueError:
      discard initPinQuery(before = some("2026-07-12"))

  test "scripted transport records redacted reaction observations":
    let scripted = newScriptedRestTransport()
    scripted.expectRequest(transportResponse(204))
    let client = newChronosRestClient(scripted.asRestTransport())
    client.start()
    waitFor client.addReaction(channelId, messageId, unicodeEmoji("👍"))
    waitFor client.stop()
    let observed = scripted.observedRequests()
    check observed[0].httpMethod == hmPut
    check observed[0].redactedPath.contains("/reactions/")
    scripted.assertSatisfied()

  test "observed request logs are owned copies":
    let scripted = newScriptedRestTransport()
    scripted.expectRequest(transportResponse(204))
    let client = newChronosRestClient(scripted.asRestTransport())
    client.start()
    waitFor client.deleteMessage(channelId, messageId)
    waitFor client.stop()
    var first = scripted.observedRequests()
    first[0].redactedPath = "mutated"
    check scripted.observedRequests()[0].redactedPath != "mutated"
