## Contract tests for semantic guild, role, ban, and prune REST operations.

import std/[json, options, strutils, unittest]

import chronos

import cordnim/api/guilds
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
    result = newFuture[TransportResponse]("test.api.guilds")
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
let roleId = RoleId.parseId("9")
let userId = UserId.parseId("3")

suite "semantic guild REST":
  test "guild fetch and edit keep query audit and tri-state semantics":
    let probe = CaptureProbe(responses: @[
      jsonResponse(200, guildJson()), jsonResponse(200, guildJson())])
    let client = probe.startedClient()
    discard waitFor client.fetchGuild(guildId, withCounts = some(true))
    discard waitFor client.editGuild(guildId,
      guildEdit(description = editClear(string),
        systemChannelId = editClear(ChannelId),
        verificationLevel = editSet(vlHigh)),
      initApiCallOptions(auditReason = some("tighten moderation")))
    waitFor client.stop()
    check probe.requests[0].urlPath.contains("with_counts=true")
    check probe.requests[0].meta.idempotency == idSafe
    let editRequest = probe.requests[1]
    check editRequest.meta.auditReason == some("tighten moderation")
    check editRequest.bodyJson()["description"].kind == JNull
    check editRequest.bodyJson()["system_channel_id"].kind == JNull
    check editRequest.bodyJson()["verification_level"].getInt() == 3

  test "role writes use decimal strings including bits above uint64":
    let wide = initDiscordBits[Permission]([0'u64, 1'u64])
    let probe = CaptureProbe(responses: @[
      jsonResponse(200, roleJson()), jsonResponse(200, roleJson()),
      jsonResponse(200, %*[roleJson()])])
    let client = probe.startedClient()
    discard waitFor client.createGuildRole(guildId,
      roleCreate(name = some("Wide"), permissions = some(wide)))
    discard waitFor client.editGuildRole(guildId, roleId,
      roleEdit(permissions = editSet(wide)))
    discard waitFor client.reorderGuildRoles(guildId,
      @[rolePosition(roleId, 2)])
    waitFor client.stop()
    check probe.requests[0].bodyJson()["permissions"].getStr() ==
      "18446744073709551616"
    check probe.requests[0].meta.idempotency == idNever
    check probe.requests[1].bodyJson()["permissions"].kind == JString
    check probe.requests[1].meta.idempotency == idSafe
    check probe.requests[2].bodyJson()[0]["position"].getInt() == 2

  test "role lists fetches and deletion are typed and safe":
    let probe = CaptureProbe(responses: @[
      jsonResponse(200, %*[roleJson()]), jsonResponse(200, roleJson()),
      transportResponse(204)])
    let client = probe.startedClient()
    check (waitFor client.listGuildRoles(guildId)).len == 1
    check (waitFor client.fetchGuildRole(guildId, roleId)).id == roleId
    waitFor client.deleteGuildRole(guildId, roleId)
    waitFor client.stop()
    for request in probe.requests:
      check request.meta.idempotency == idSafe

  test "ban endpoints preserve cursor bodies and retry policy":
    let probe = CaptureProbe(responses: @[
      jsonResponse(200, %*[banJson()]), jsonResponse(200, banJson()),
      transportResponse(204), transportResponse(204),
      jsonResponse(200, %*{"banned_users": ["3"], "failed_users": []})])
    let client = probe.startedClient()
    discard waitFor client.listGuildBans(guildId,
      banQuery(limit = some(50), after = some(UserId.parseId("2"))))
    discard waitFor client.fetchGuildBan(guildId, userId)
    waitFor client.banGuildMember(guildId, userId,
      banCreate(deleteMessageSeconds = some(3600)))
    waitFor client.unbanGuildMember(guildId, userId)
    let result = waitFor client.bulkBanGuildMembers(guildId,
      bulkBan(@[userId]))
    waitFor client.stop()
    check result.bannedUsers == @[userId]
    check probe.requests[0].urlPath.contains("limit=50")
    check probe.requests[0].urlPath.contains("after=2")
    check probe.requests[2].bodyJson()["delete_message_seconds"].getInt() == 3600
    check probe.requests[3].bodyJson() == newJObject()
    check probe.requests[4].meta.idempotency == idNever

  test "prune preview and execution encode their distinct wire forms":
    let probe = CaptureProbe(responses: @[
      jsonResponse(200, %*{"pruned": 3}),
      jsonResponse(200, %*{"pruned": nil})])
    let client = probe.startedClient()
    let preview = waitFor client.previewGuildPrune(guildId,
      prunePreviewQuery(days = some(7), includeRoles = @[roleId]))
    let executed = waitFor client.pruneGuildMembers(guildId,
      pruneRequest(days = some(14), computePruneCount = some(false),
        includeRoles = @[roleId]))
    waitFor client.stop()
    check preview.pruned == some(3'i64)
    check executed.pruned.isNone
    check probe.requests[0].urlPath.contains("days=7")
    check probe.requests[0].urlPath.contains("include_roles=9")
    check probe.requests[0].meta.idempotency == idSafe
    let body = probe.requests[1].bodyJson()
    check not body["compute_prune_count"].getBool()
    check body["include_roles"] == %*["9"]
    check probe.requests[1].meta.idempotency == idNever

  test "ambiguous and oversized requests fail locally":
    expect ValueError:
      discard banQuery(before = some(UserId.parseId("1")),
        after = some(UserId.parseId("2")))
    expect ValueError:
      discard banCreate(deleteMessageSeconds = some(604_801))
    expect ValueError:
      discard roleCreate(color = some(1),
        colors = some(RoleColors(primaryColor: 1)))
    expect ValueError:
      discard prunePreviewQuery(days = some(31))
