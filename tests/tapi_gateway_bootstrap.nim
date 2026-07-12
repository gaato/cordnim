## Typed Gateway bootstrap API tests.

import std/[json, unittest]

import chronos

import cordnim/api/gateway_bootstrap
import cordnim/core/errors
import cordnim/gateway/identify
import cordnim/rest/[chronos_driver, request]

type RestProbe = ref object
  requests: seq[RawRequest]
  response: TransportResponse

proc asTransport(probe: RestProbe): RestTransport =
  result = proc(cordRequest: RawRequest): Future[TransportResponse] {.
      closure, gcsafe, raises: [].} =
    probe.requests.add(cordRequest)
    result = newFuture[TransportResponse]("test.gateway.bootstrap")
    result.complete(probe.response)

proc bytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for index, value in text:
    result[index] = byte(ord(value))

let validGatewayBot = %*{
  "url": "wss://gateway.discord.gg/",
  "shards": 9,
  "session_start_limit": {
    "total": 1000,
    "remaining": 999,
    "reset_after": 14_400_000,
    "max_concurrency": 2
  },
  "future_field": {"enabled": true}
}

suite "Gateway bootstrap API":
  test "strictly decodes limits and retains isolated unknown fields":
    let info = decodeGatewayBotInfo(validGatewayBot)
    check info.url == "wss://gateway.discord.gg/"
    check info.recommendedShards == 9
    check info.sessionStartLimit.total == 1000
    check info.sessionStartLimit.remaining == 999
    check info.sessionStartLimit.resetAfterMs == 14_400_000
    check info.sessionStartLimit.maxConcurrency == 2
    check info.unknownFields.len == 1

    var raw = info.rawJson()
    raw["url"] = %"mutated"
    var unknown = info.unknownFields()
    unknown[0].value["enabled"] = %false
    check info.rawJson()["url"].getStr() == "wss://gateway.discord.gg/"
    check info.unknownFields()[0].value["enabled"].getBool()

  test "rejects malformed counters at the decode boundary":
    var malformed = validGatewayBot.copy()
    malformed["session_start_limit"]["remaining"] = %1001
    expect DecodeError:
      discard decodeGatewayBotInfo(malformed)

  test "accepts Discord's fully-reset zero reset duration":
    var fullyReset = validGatewayBot.copy()
    fullyReset["session_start_limit"]["remaining"] = %1000
    fullyReset["session_start_limit"]["reset_after"] = %0
    let info = decodeGatewayBotInfo(fullyReset)
    check info.sessionStartLimit.resetAfterMs == 0

  test "submits a safe retryable route and returns a shard plan":
    let probe = RestProbe(response: TransportResponse(
      status: 200, body: bytes($validGatewayBot)))
    let client = newChronosRestClient(probe.asTransport())
    client.start()
    let info = waitFor client.getGatewayBot()
    check probe.requests.len == 1
    check probe.requests[0].route.canonical == "GET /gateway/bot"
    check probe.requests[0].meta.idempotency == idSafe
    check probe.requests[0].authRequirement == darBot
    let plan = info.planRecommendedShards(processIndex = 1, processCount = 3)
    check plan.totalShards == 9
    check plan.owned.first == 3
    check plan.owned.lastExclusive == 6
    let coordinator = info.initIdentifyCoordinator(nowMs = 50)
    check coordinator.remaining == 999
    check coordinator.maxConcurrency == 2
    waitFor client.stop()
