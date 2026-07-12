## Contract tests for semantic guild-channel REST operations.

import std/[json, options, unittest]

import chronos

import cordnim/api/channels
import cordnim/rest
import cordnim/testing

import ./api_semantic_fixtures

type CaptureProbe = ref object
  requests: seq[RawRequest]
  responses: seq[TransportResponse]
  cursor: int

proc asTransport(probe: CaptureProbe): RestTransport =
  result = proc(request: RawRequest): Future[TransportResponse] {.
      gcsafe, raises: [].} =
    doAssert request.authRequirement == darBot
    probe.requests.add(request)
    let response = if probe.cursor < probe.responses.len:
      probe.responses[probe.cursor] else: probe.responses[^1]
    inc probe.cursor
    result = newFuture[TransportResponse]("test.api.channels")
    result.complete(response)

proc startedClient(probe: CaptureProbe): ChronosRestClient =
  result = newChronosRestClient(probe.asTransport())
  result.start()

func bytesText(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for index, value in bytes:
    result[index] = char(value)

proc bodyJson(request: RawRequest): JsonNode =
  parseJson(request.body.bodyBytes().bytesText())

let guildId = GuildId.parseId("7")
let channelId = ChannelId.parseId("42")

suite "semantic channel REST":
  test "channel creation writes decimal permission strings and is not retried":
    let allow = initDiscordBits[Permission]([Permission.viewChannel])
    let create = guildChannelCreate("ops", kind = ctGuildText,
      permissionOverwrites = @[
        roleOverwrite(RoleId.parseId("9"), allow = allow)],
      defaultAutoArchiveDuration = some(taadOneDay),
      availableTags = @[forumTag("Support",
        emoji = some(unicodeForumEmoji("🛟")))])
    let probe = CaptureProbe(responses: @[jsonResponse(201, channelJson())])
    let client = probe.startedClient()
    discard waitFor client.createGuildChannel(guildId, create,
      initApiCallOptions(auditReason = some("provision support channel")))
    waitFor client.stop()
    let request = probe.requests[0]
    check request.meta.idempotency == idNever
    check request.meta.auditReason == some("provision support channel")
    let body = request.bodyJson()
    check body["permission_overwrites"][0]["allow"].kind == JString
    check body["permission_overwrites"][0]["allow"].getStr() == "1024"
    check body["permission_overwrites"][0]["deny"].getStr() == "0"
    check body["default_auto_archive_duration"].getInt() == 1440
    check body["available_tags"][0]["emoji_name"].getStr() == "🛟"

  test "channel edit preserves omit clear and set":
    let probe = CaptureProbe(responses: @[jsonResponse(200, channelJson())])
    let client = probe.startedClient()
    discard waitFor client.editChannel(channelId,
      channelEdit(topic = editClear(string), nsfw = editSet(true),
        parentId = editClear(ChannelId)))
    waitFor client.stop()
    let request = probe.requests[0]
    check request.meta.idempotency == idSafe
    let body = request.bodyJson()
    check body["topic"].kind == JNull
    check body["parent_id"].kind == JNull
    check body["nsfw"].getBool()
    check not body.hasKey("name")

  test "guild channel lists accept a pinned null collection":
    let probe = CaptureProbe(responses: @[jsonResponse(200, newJNull())])
    let client = probe.startedClient()
    check (waitFor client.listGuildChannels(guildId)).len == 0
    waitFor client.stop()

  test "reorder and overwrite operations are safe and audited":
    let allow = initDiscordBits[Permission]([Permission.sendMessages])
    let probe = CaptureProbe(responses: @[
      transportResponse(204), transportResponse(204), transportResponse(204)])
    let client = probe.startedClient()
    waitFor client.reorderGuildChannels(guildId, @[
      channelPosition(channelId, position = some(3),
        parentId = editClear(ChannelId))])
    waitFor client.setChannelPermissionOverwrite(channelId,
      memberOverwrite(UserId.parseId("2"), allow = allow))
    waitFor client.deleteChannelPermissionOverwrite(
      channelId, UserId.parseId("2"))
    waitFor client.stop()
    check probe.requests[0].bodyJson()[0]["parent_id"].kind == JNull
    check probe.requests[1].bodyJson()["allow"].getStr() == "2048"
    for request in probe.requests:
      check request.meta.idempotency == idSafe

  test "delete typing and follow use operation-owned retry contracts":
    let probe = CaptureProbe(responses: @[
      jsonResponse(200, channelJson()), transportResponse(200),
      jsonResponse(200, %*{"channel_id": "42", "webhook_id": "99"})])
    let client = probe.startedClient()
    discard waitFor client.deleteChannel(channelId)
    waitFor client.triggerTyping(channelId)
    let followed = waitFor client.followAnnouncementChannel(
      channelId, ChannelId.parseId("44"))
    waitFor client.stop()
    check followed.webhookId == WebhookId.parseId("99")
    check probe.requests[0].meta.idempotency == idNever
    check probe.requests[1].meta.idempotency == idNever
    check probe.requests[2].meta.idempotency == idNever
    check probe.requests[2].bodyJson()["webhook_channel_id"].getStr() == "44"

  test "invalid bounds and duplicate targets fail before transport":
    expect ValueError:
      discard guildChannelCreate("")
    let probe = CaptureProbe(responses: @[jsonResponse(200, channelJson())])
    let client = probe.startedClient()
    expect ValueError:
      discard waitFor client.editChannel(channelId,
        channelEdit(rateLimitPerUser = editSet(21_601)))
    expect ValueError:
      discard waitFor client.editChannel(channelId,
        channelEdit(name = editSet("")))
    expect ValueError:
      discard waitFor client.editChannel(channelId,
        channelEdit(name = editClear(string)))
    waitFor client.stop()
    check probe.requests.len == 0
    expect ValueError:
      discard guildChannelCreate("x", permissionOverwrites = @[
        roleOverwrite(RoleId.parseId("9")),
        roleOverwrite(RoleId.parseId("9"))])
