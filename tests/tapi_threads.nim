## Contract tests for semantic thread REST operations.

import std/[json, options, strutils, unittest]

import chronos

import cordnim/api/[messages, threads]
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
    result = newFuture[TransportResponse]("test.api.threads")
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
let threadId = ChannelId.parseId("43")
let messageId = MessageId.parseId("100")
let userId = UserId.parseId("2")

suite "semantic thread REST":
  test "all JSON thread creation forms use 201 and no automatic retry":
    let probe = CaptureProbe(responses: @[
      jsonResponse(201, threadJson()), jsonResponse(201, threadJson()),
      jsonResponse(201, threadJson())])
    let client = probe.startedClient()
    discard waitFor client.createThreadFromMessage(channelId, messageId,
      threadFromMessage("message topic", rateLimitPerUser = some(5)))
    discard waitFor client.createStandaloneThread(channelId,
      standaloneThread("private topic", kind = ctPrivateThread,
        invitable = some(true)))
    discard waitFor client.createForumThread(channelId,
      forumThread("question", legacyMessage("starter"),
        appliedTags = @[ForumTagId.parseId("8")]))
    waitFor client.stop()
    for request in probe.requests:
      check request.meta.idempotency == idNever
    check probe.requests[0].bodyJson()["rate_limit_per_user"].getInt() == 5
    check probe.requests[1].bodyJson()["type"].getInt() == 12
    let forum = probe.requests[2].bodyJson()
    check forum["message"]["content"].getStr() == "starter"
    check forum["message"]["allowed_mentions"] == %*{"parse": []}
    check forum["applied_tags"] == %*["8"]

  test "active and archived listings keep their cursor types":
    let listing = threadListingJson(true)
    let probe = CaptureProbe(responses: @[
      jsonResponse(200, listing), jsonResponse(200, listing),
      jsonResponse(200, listing), jsonResponse(200, listing)])
    let client = probe.startedClient()
    check (waitFor client.listActiveGuildThreads(guildId)).threads.len == 1
    discard waitFor client.listPublicArchivedThreads(channelId,
      archivedThreadQuery(before = some("2026-07-01T00:00:00Z"),
        limit = some(50)))
    discard waitFor client.listPrivateArchivedThreads(channelId)
    discard waitFor client.listMyPrivateArchivedThreads(channelId,
      myArchivedThreadQuery(before = some(ChannelId.parseId("40")),
        limit = some(25)))
    waitFor client.stop()
    check probe.requests[1].urlPath.contains("before=2026-07-01T00%3A00%3A00Z")
    check probe.requests[1].urlPath.contains("limit=50")
    check probe.requests[3].urlPath.contains("before=40")
    for request in probe.requests:
      check request.meta.idempotency == idSafe

  test "thread member reads are strict and query expansion is explicit":
    let probe = CaptureProbe(responses: @[
      jsonResponse(200, %*[threadMemberJson(withMember = true)]),
      jsonResponse(200, threadMemberJson(withMember = true))])
    let client = probe.startedClient()
    let members = waitFor client.listThreadMembers(threadId,
      threadMemberQuery(withMember = some(true),
        after = some(UserId.parseId("1")), limit = some(100)))
    let member = waitFor client.fetchThreadMember(threadId, userId,
      withMember = some(true))
    waitFor client.stop()
    check members[0].member.isSome
    check member.userId == some(userId)
    check probe.requests[0].urlPath.contains("with_member=true")
    check probe.requests[0].urlPath.contains("after=1")
    check probe.requests[1].urlPath.contains("with_member=true")

  test "thread membership writes are idempotent":
    let probe = CaptureProbe(responses: @[
      transportResponse(204), transportResponse(204),
      transportResponse(204), transportResponse(204)])
    let client = probe.startedClient()
    waitFor client.joinThread(threadId)
    waitFor client.leaveThread(threadId)
    waitFor client.addThreadMember(threadId, userId)
    waitFor client.removeThreadMember(threadId, userId)
    waitFor client.stop()
    for request in probe.requests:
      check request.meta.idempotency == idSafe

  test "invalid cursor and starter-message shapes fail locally":
    expect ValueError:
      discard archivedThreadQuery(before = some("2026-07-01"))
    expect ValueError:
      discard myArchivedThreadQuery(limit = some(1))
    expect ValueError:
      discard standaloneThread("public", kind = ctPublicThread,
        invitable = some(true))
    expect ValueError:
      discard forumThread("empty", legacyMessage())
