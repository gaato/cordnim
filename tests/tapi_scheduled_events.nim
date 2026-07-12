## Contract tests for semantic scheduled-event REST operations.

import std/[json, options, strutils, unittest]

import chronos

import cordnim/api/scheduled_events
import cordnim/core/[ids, open_enums]
import cordnim/rest
import cordnim/testing

type CaptureProbe = ref object
  requests: seq[RawRequest]
  responses: seq[TransportResponse]
  cursor: int

proc eventJson(status = 1): JsonNode =
  %*{
    "id": "90", "guild_id": "7", "channel_id": "42",
    "creator_id": "2", "name": "Meeting", "description": nil,
    "scheduled_start_time": "2027-02-22T11:00:00Z",
    "scheduled_end_time": nil, "privacy_level": 2, "status": status,
    "entity_type": 2, "entity_id": nil, "entity_metadata": nil,
    "user_count": 4, "image": nil, "future_field": "retained",
  }

proc asTransport(probe: CaptureProbe): RestTransport =
  result = proc(request: RawRequest): Future[TransportResponse] {.
      gcsafe, raises: [].} =
    probe.requests.add(request)
    let response = probe.responses[min(probe.cursor, probe.responses.high)]
    inc probe.cursor
    result = newFuture[TransportResponse]("test.api.scheduled-events")
    result.complete(response)

proc startedClient(probe: CaptureProbe): ChronosRestClient =
  result = newChronosRestClient(probe.asTransport())
  result.start()

func bodyText(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for index, value in bytes:
    result[index] = char(value)

proc requestBody(request: RawRequest): JsonNode =
  parseJson(request.body.bodyBytes().bodyText())

suite "semantic scheduled-event REST":
  test "decodes resources and preserves future fields":
    let event = decodeScheduledEvent(eventJson())
    check event.id == ScheduledEventId.parseId("90")
    check event.channelId == some(ChannelId.parseId("42"))
    check event.entityType.knownValue == some(seetVoice)
    check event.status.knownValue == some(sesScheduled)
    check event.userCount == some(4'i64)
    check event.unknownFields()[0].name == "future_field"

  test "creates lists starts and deletes events with owned retry policy":
    let probe = CaptureProbe(responses: @[
      jsonResponse(200, %*[eventJson()]),
      jsonResponse(200, eventJson()),
      jsonResponse(200, eventJson(status = 2)),
      transportResponse(204),
    ])
    let client = probe.startedClient()
    discard waitFor client.listScheduledEvents(
      GuildId.parseId("7"), withUserCount = true)
    discard waitFor client.createScheduledEvent(GuildId.parseId("7"),
      voiceScheduledEvent("Meeting", ChannelId.parseId("42"),
        "2027-02-22T11:00:00Z", description = some("Weekly")))
    discard waitFor client.editScheduledEvent(
      GuildId.parseId("7"), ScheduledEventId.parseId("90"),
      scheduledEventEdit(status = some(sesActive)))
    waitFor client.deleteScheduledEvent(
      GuildId.parseId("7"), ScheduledEventId.parseId("90"))
    waitFor client.stop()
    check probe.requests[0].urlPath.endsWith("with_user_count=true")
    check probe.requests[0].meta.idempotency == idSafe
    check probe.requests[1].meta.idempotency == idNever
    check probe.requests[1].requestBody()["channel_id"].getStr() == "42"
    check probe.requests[1].requestBody()["entity_type"].getInt() == 2
    check probe.requests[2].requestBody()["status"].getInt() == 2
    check probe.requests[2].meta.idempotency == idSafe
    check probe.requests[3].meta.idempotency == idSafe

  test "external and edit builders enforce entity-specific fields":
    let external = externalScheduledEvent("Offsite", "Tokyo",
      "2027-02-22T11:00:00Z", "2027-02-22T12:00:00Z")
    let probe = CaptureProbe(responses: @[jsonResponse(200, eventJson())])
    let client = probe.startedClient()
    discard waitFor client.createScheduledEvent(GuildId.parseId("7"), external)
    waitFor client.stop()
    let body = probe.requests[0].requestBody()
    check body["entity_type"].getInt() == 3
    check body["entity_metadata"]["location"].getStr() == "Tokyo"
    check body["scheduled_end_time"].getStr().endsWith("12:00:00Z")
    expect ValueError:
      discard voiceScheduledEvent("Bad", ChannelId.parseId("42"),
        "not-a-time")
    expect ValueError:
      discard externalScheduledEvent("Bad", "", "2027-02-22T11:00:00Z",
        "2027-02-22T12:00:00Z")
