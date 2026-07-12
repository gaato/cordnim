## Typed `/gateway/bot` bootstrap over the rate-aware REST client.

import std/[json, options]

import chronos

import cordnim/api/internal/execute
import cordnim/core/errors
import cordnim/gateway/[identify, sharding]
import cordnim/raw/model as raw_model
import cordnim/raw/request as raw_request
import cordnim/raw/routes/gateway as gateway_routes
import cordnim/rest/[chronos_driver, request]

type
  GatewayBotInfo* = object ## Current Gateway URL, shard advice, and IDENTIFY
                           ## allowance returned for an authenticated bot.
    url*: string ## WSS base URL used to construct Gateway v10 connections.
    recommendedShards*: uint16 ## Discord's recommended total shard count.
    sessionStartLimit*: SessionStartLimit ## Current IDENTIFY budget and
                                          ## concurrency buckets.
    snapshot: JsonNode

const gatewayBotKnownFields = ["url", "shards", "session_start_limit"]

proc rawJson*(info: GatewayBotInfo): JsonNode =
  ## Returns an owned copy of the complete `/gateway/bot` response.
  if info.snapshot.isNil: nil else: info.snapshot.copy()

proc unknownFields*(info: GatewayBotInfo): seq[RawField] =
  ## Returns owned copies of fields unknown to this Cordnim revision.
  for field in raw_model.unknownFields(info.snapshot, gatewayBotKnownFields):
    result.add(RawField(
      name: field.name,
      value: if field.value.isNil: nil else: field.value.copy()))

proc decodeFailure(message: string): ref DecodeError =
  newDiscordError(
    DecodeError,
    message,
    initDiscordFailureMeta(route = some("GET /gateway/bot"))
  )

proc requiredObject(parent: JsonNode; name: string): JsonNode =
  if parent.isNil or parent.kind != JObject or not parent.hasKey(name) or
      parent[name].kind != JObject:
    raise decodeFailure("Gateway bot response field '" & name &
      "' must be an object")
  parent[name]

proc requiredInt(parent: JsonNode; name: string): BiggestInt =
  if parent.isNil or parent.kind != JObject or not parent.hasKey(name) or
      parent[name].kind != JInt:
    raise decodeFailure("Gateway bot response field '" & name &
      "' must be an integer")
  parent[name].getBiggestInt()

proc decodeGatewayBotInfo*(document: JsonNode): GatewayBotInfo =
  ## Strictly decodes a `/gateway/bot` JSON object.
  ##
  ## Required fields and numeric invariants are checked at the REST boundary;
  ## unknown properties remain available through `rawJson` and
  ## `unknownFields` without exposing the stored snapshot for mutation.
  if document.isNil or document.kind != JObject:
    raise decodeFailure("Gateway bot response must be a JSON object")
  if not document.hasKey("url") or document["url"].kind != JString or
      document["url"].getStr().len == 0:
    raise decodeFailure(
      "Gateway bot response field 'url' must be a non-empty string")
  let shards = document.requiredInt("shards")
  if shards < 1 or shards > BiggestInt(high(uint16)):
    raise decodeFailure(
      "Gateway bot response shard count is outside the supported range")

  let limit = document.requiredObject("session_start_limit")
  let total = limit.requiredInt("total")
  let remaining = limit.requiredInt("remaining")
  let resetAfter = limit.requiredInt("reset_after")
  let maxConcurrency = limit.requiredInt("max_concurrency")
  if total < 0 or total > BiggestInt(high(int)) or remaining < 0 or
      remaining > total or remaining > BiggestInt(high(int)):
    raise decodeFailure("Gateway bot session-start counters are invalid")
  if resetAfter < 0 or resetAfter > BiggestInt(high(int64)):
    raise decodeFailure(
      "Gateway bot session-start reset duration is invalid")
  if maxConcurrency < 1 or maxConcurrency > BiggestInt(high(uint16)):
    raise decodeFailure(
      "Gateway bot session-start concurrency is invalid")

  GatewayBotInfo(
    url: document["url"].getStr(),
    recommendedShards: uint16(shards),
    sessionStartLimit: SessionStartLimit(
      total: int(total),
      remaining: int(remaining),
      resetAfterMs: int64(resetAfter),
      maxConcurrency: uint16(maxConcurrency)
    ),
    snapshot: document.copy()
  )

proc decodeGatewayBotInfo*(encoded: string): GatewayBotInfo =
  ## Parses and decodes an encoded `/gateway/bot` response.
  try:
    decodeGatewayBotInfo(parseJson(encoded))
  except DecodeError:
    raise
  except CatchableError:
    raise decodeFailure("Gateway bot response is not valid JSON")

proc getGatewayBot*(client: ChronosRestClient): Future[GatewayBotInfo] {.
    async.} =
  ## Fetches current shard advice and IDENTIFY limits through the REST scheduler.
  if client.isNil:
    raise newException(ValueError, "Gateway bootstrap requires a REST client")
  var meta = defaultRequestMeta()
  meta.idempotency = idSafe
  let raw = raw_request.initRawRequest(gateway_routes.getBotGateway)
  return await client.executeJson(
    raw, decodeGatewayBotInfo, auth = darBot, meta = meta)

proc planRecommendedShards*(info: GatewayBotInfo;
                            processIndex = 0'u16;
                            processCount = 1'u16): ShardPlan =
  ## Builds a validated process-local plan from Discord's recommended count.
  planShards(info.recommendedShards, processIndex, processCount)

proc initIdentifyCoordinator*(info: GatewayBotInfo;
                              nowMs: int64): IdentifyCoordinator =
  ## Initializes IDENTIFY accounting from the same bootstrap response.
  identify.initIdentifyCoordinator(info.sessionStartLimit, nowMs)
