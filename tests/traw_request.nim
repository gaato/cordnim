import std/[assertions, json, jsonutils, strutils]

import cordnim/raw/[request, route, routes]

block generated_route_request:
  var request = initRawRequest(
    createMessage,
    [initRawParameter("channel_id", "42")],
    %*{"content": "hello"}
  )
  request.addQuery("wait", "true")
  request.addQuery("cursor", "space / slash")
  request.setHeader("Authorization", "Bot secret")
  request.setHeader("authorization", "Bot replacement")

  doAssert request.path == "/channels/42/messages"
  doAssert request.majorParameter == "channel_id=42"
  doAssert request.query.len == 2
  doAssert request.renderedPath ==
    "/channels/42/messages?wait=true&cursor=space%20%2F%20slash"
  doAssert request.headers.len == 1
  doAssert request.headers[0].value == "Bot replacement"
  doAssert "channels/42" notin $request
  doAssert "secret" notin $request
  doAssert "replacement" notin $request
  for rendered in [repr(request), $(%request), $request.toJson()]:
    doAssert "channels/42" notin rendered
    doAssert "replacement" notin rendered

block escape_hatch_for_new_stable_endpoint:
  let request = initRawRequest(
    httpPost,
    "/applications/1/future-endpoint",
    %*{"value": 1},
    operationId = "future_endpoint"
  )
  doAssert request.route.operationId == "future_endpoint"
  doAssert request.route.hasRequestBody

block escape_hatch_log_does_not_expose_path_tokens:
  let request = initRawRequest(
    httpPost,
    "/webhooks/1/interaction-token-value",
    operationId = "operation-token-value"
  )
  for rendered in [$request, repr(request), $(%request), $request.toJson()]:
    doAssert "interaction-token-value" notin rendered
    doAssert "operation-token-value" notin rendered

block escape_hatch_rejects_full_url:
  doAssertRaises RawRouteError:
    discard initRawRequest(httpGet, "https://discord.com/api/v10/users/@me")
