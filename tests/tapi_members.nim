## Contract tests for semantic guild-member REST operations.

import std/[json, jsonutils, options, strutils, unittest]

import chronos

import cordnim/api/members
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
    result = newFuture[TransportResponse]("test.api.members")
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
let userId = UserId.parseId("2")
let roleId = RoleId.parseId("9")

suite "semantic member REST":
  test "member list search and fetch use bounded typed queries":
    let probe = CaptureProbe(responses: @[
      jsonResponse(200, %*[memberJson()]),
      jsonResponse(200, %*[memberJson()]),
      jsonResponse(200, memberJson())])
    let client = probe.startedClient()
    discard waitFor client.listGuildMembers(guildId,
      memberListQuery(limit = some(100), after = some(UserId.parseId("1"))))
    discard waitFor client.searchGuildMembers(guildId,
      memberSearchQuery("cor", limit = some(25)))
    let member = waitFor client.fetchGuildMember(guildId, userId)
    waitFor client.stop()
    check member.user.get.id == userId
    check probe.requests[0].urlPath.contains("limit=100")
    check probe.requests[0].urlPath.contains("after=1")
    check probe.requests[1].urlPath.contains("query=cor")
    for request in probe.requests:
      check request.meta.idempotency == idSafe

  test "member add keeps the OAuth token out of diagnostics":
    const sentinel = "oauth-user-token-SENTINEL"
    let create = memberAdd(sentinel, nick = some("Cord"),
      roleIds = @[roleId])
    check sentinel notin $create
    check sentinel notin repr(create)
    check sentinel notin $(%create)
    check sentinel notin $jsonutils.toJson(create)
    let probe = CaptureProbe(responses: @[
      jsonResponse(201, memberJson()), transportResponse(204)])
    let client = probe.startedClient()
    check (waitFor client.addGuildMember(guildId, userId, create)).isSome
    check (waitFor client.addGuildMember(guildId, userId, create)).isNone
    waitFor client.stop()
    let body = probe.requests[0].bodyJson()
    check body["access_token"].getStr() == sentinel
    check body["roles"] == %*["9"]
    for request in probe.requests:
      check request.meta.idempotency == idSafe

  test "member edit and current profile edit preserve clear semantics":
    let probe = CaptureProbe(responses: @[
      jsonResponse(200, memberJson()), transportResponse(204),
      jsonResponse(200, memberJson())])
    let client = probe.startedClient()
    check (waitFor client.editGuildMember(guildId, userId,
      memberEdit(nick = editClear(string),
        channelId = editClear(ChannelId),
        communicationDisabledUntil =
          editSet("2026-07-20T00:00:00Z")))).isSome
    check (waitFor client.editGuildMember(guildId, userId,
      memberEdit(mute = editSet(false)))).isNone
    discard waitFor client.editMyGuildMember(guildId,
      myMemberEdit(nick = editSet("Bot"), bio = editClear(string)))
    waitFor client.stop()
    let body = probe.requests[0].bodyJson()
    check body["nick"].kind == JNull
    check body["channel_id"].kind == JNull
    check body["communication_disabled_until"].getStr().endsWith("Z")
    check probe.requests[2].bodyJson()["bio"].kind == JNull

  test "kick and role membership routes are idempotent":
    let probe = CaptureProbe(responses: @[
      transportResponse(204), transportResponse(204), transportResponse(204)])
    let client = probe.startedClient()
    waitFor client.addGuildMemberRole(guildId, userId, roleId)
    waitFor client.removeGuildMemberRole(guildId, userId, roleId)
    waitFor client.kickGuildMember(guildId, userId,
      initApiCallOptions(auditReason = some("requested removal")))
    waitFor client.stop()
    for request in probe.requests:
      check request.meta.idempotency == idSafe
    check probe.requests[2].meta.auditReason == some("requested removal")

  test "invalid member requests fail before network I/O":
    expect ValueError:
      discard memberSearchQuery("")
    expect ValueError:
      discard memberListQuery(limit = some(1001))
    expect ValueError:
      discard memberAdd("")
    let probe = CaptureProbe(responses: @[jsonResponse(200, memberJson())])
    let client = probe.startedClient()
    expect ValueError:
      discard waitFor client.editGuildMember(guildId, userId,
        memberEdit(communicationDisabledUntil = editSet("next week")))
    waitFor client.stop()
    check probe.requests.len == 0
