import std/[assertions, options, strutils]

import cordnim/raw/[route, routes, schema_info]

block complete_stable_inventory:
  doAssert allRoutes.len == discordOperationCount
  doAssert discordOperationCount == 242

  var operationIds: seq[string]
  for route in allRoutes:
    doAssert route.pathTemplate.startsWith("/")
    doAssert route.operationId.len > 0
    doAssert route.operationId notin operationIds
    operationIds.add route.operationId
    doAssert findRoute(route.operationId).isSome

block render_typed_route:
  let path = getChannel.renderPath([
    initRawParameter("channel_id", "room/with space")
  ])
  doAssert path == "/channels/room%2Fwith%20space"

block missing_parameter_is_rejected:
  doAssertRaises RawRouteError:
    discard getChannel.renderPath()

block unused_parameter_is_rejected:
  doAssertRaises RawRouteError:
    discard getChannel.renderPath([
      initRawParameter("channel_id", "1"),
      initRawParameter("guild_id", "2")
    ])

block duplicate_parameter_is_rejected:
  doAssertRaises RawRouteError:
    discard getChannel.renderPath([
      initRawParameter("channel_id", "1"),
      initRawParameter("channel_id", "2")
    ])

block provisional_rate_limit_key:
  let first = listMessages.rateLimitKey([
    initRawParameter("channel_id", "10")
  ])
  let second = getMessage.rateLimitKey([
    initRawParameter("channel_id", "10"),
    initRawParameter("message_id", "20")
  ])
  doAssert first == "GET/channels/10/messages"
  doAssert second == "GET/channels/10/messages/:message_id"

block webhook_token_is_not_part_of_diagnostic_bucket_key:
  let key = executeWebhook.rateLimitKey([
    initRawParameter("webhook_id", "10"),
    initRawParameter("webhook_token", "credential-value")
  ])
  doAssert "credential-value" notin key
  doAssert key == "POST/webhooks/10/:webhook_token"

  let major = executeWebhook.majorParameterKey([
    initRawParameter("webhook_id", "10"),
    initRawParameter("webhook_token", "credential-value")
  ])
  doAssert major == "webhook_id=10"
  doAssert "credential-value" notin major
