## Tests for the shared semantic REST execution boundary.

import std/[json, options, strutils, unittest]

import chronos

import cordnim/api/internal/execute
import cordnim/core/errors
import cordnim/raw/request as raw_request
import cordnim/raw/route as raw_route
import cordnim/rest/chronos_driver
import cordnim/rest/request as runtime_request

type RestProbe = ref object
  requests: seq[runtime_request.RawRequest]
  response: TransportResponse

proc asTransport(probe: RestProbe): RestTransport =
  result = proc(cordRequest: runtime_request.RawRequest):
      Future[TransportResponse] {.
      closure, gcsafe, raises: [].} =
    probe.requests.add(cordRequest)
    result = newFuture[TransportResponse]("test.api.execute")
    result.complete(probe.response)

proc bytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for index, value in text:
    result[index] = byte(value)

proc decodeName(document: JsonNode): string =
  if document.kind != JObject or not document.hasKey("name") or
      document["name"].kind != JString:
    raise newDiscordError(DecodeError, "name is required")
  document["name"].getStr()

suite "semantic REST execution":
  test "routes JSON through the checked scheduler boundary":
    let probe = RestProbe(response: TransportResponse(
      status: 200, body: bytes("""{"name":"cordnim"}""")))
    let client = newChronosRestClient(probe.asTransport())
    client.start()
    let raw = raw_request.initRawRequest(raw_route.httpGet, "/semantic-test")
    var meta = runtime_request.defaultRequestMeta()
    meta.idempotency = runtime_request.idSafe
    check (waitFor client.executeJson(raw, decodeName, meta)) == "cordnim"
    check probe.requests.len == 1
    check probe.requests[0].route.canonical == "GET /semantic-test"
    check probe.requests[0].meta.idempotency == runtime_request.idSafe
    check probe.requests[0].authRequirement == runtime_request.darConfigured
    waitFor client.stop()

  test "semantic operations carry operation-owned auth requirements":
    let probe = RestProbe(response: TransportResponse(
      status: 200, body: bytes("""{"name":"oauth"}""")))
    let client = newChronosRestClient(probe.asTransport())
    client.start()
    let raw = raw_request.initRawRequest(raw_route.httpGet, "/oauth")
    check (waitFor client.executeJson(
      raw, decodeName, auth = runtime_request.darOAuthBearer)) == "oauth"
    check probe.requests[0].authRequirement == runtime_request.darOAuthBearer
    waitFor client.stop()

  test "array decoding accepts null only when the caller opts in":
    let probe = RestProbe(response: TransportResponse(
      status: 200, body: bytes("null")))
    let client = newChronosRestClient(probe.asTransport())
    client.start()
    let raw = raw_request.initRawRequest(raw_route.httpGet, "/list")
    check (waitFor client.executeJsonArray(raw, decodeName,
      allowNull = true)).len == 0
    expect DecodeError:
      discard waitFor client.executeJsonArray(raw, decodeName)
    waitFor client.stop()

  test "decode diagnostics contain the route but not response bytes":
    let privateBody = "private-response-bytes"
    let probe = RestProbe(response: TransportResponse(
      status: 200, body: bytes(privateBody)))
    let client = newChronosRestClient(probe.asTransport())
    client.start()
    let raw = raw_request.initRawRequest(raw_route.httpGet, "/safe-route")
    try:
      discard waitFor client.executeJson(raw, decodeName)
      check false
    except DecodeError as error:
      check error.metadata.route == some("GET /safe-route")
      check privateBody notin error.msg
    waitFor client.stop()

  test "no-content execution still converts HTTP failures":
    let probe = RestProbe(response: TransportResponse(status: 403))
    let client = newChronosRestClient(probe.asTransport())
    client.start()
    let raw = raw_request.initRawRequest(raw_route.httpDelete, "/forbidden")
    expect PermissionError:
      waitFor client.executeNoContent(raw)
    waitFor client.stop()

  test "optional JSON distinguishes an empty successful response":
    let probe = RestProbe(response: TransportResponse(status: 204))
    let client = newChronosRestClient(probe.asTransport())
    client.start()
    let raw = raw_request.initRawRequest(raw_route.httpPost, "/maybe-created")
    check (waitFor client.executeOptionalJson(raw, decodeName,
      statuses = {SuccessStatus(204)})).isNone
    probe.response = TransportResponse(
      status: 201, body: bytes("""{"name":"created"}"""))
    check (waitFor client.executeOptionalJson(raw, decodeName,
      statuses = {SuccessStatus(201)})) ==
      some("created")
    waitFor client.stop()

  test "optional JSON rejects bodies forbidden by 204 and 205":
    let probe = RestProbe()
    let client = newChronosRestClient(probe.asTransport())
    client.start()
    let raw = raw_request.initRawRequest(raw_route.httpPost, "/no-content")
    for status in [204, 205]:
      probe.response = TransportResponse(
        status: status,
        body: bytes("""{"name":"must-not-exist"}"""))
      try:
        discard waitFor client.executeOptionalJson(
          raw, decodeName, statuses = {SuccessStatus(status)})
        check false
      except DecodeError as error:
        check error.metadata.status == some(status)
        check "must-not-exist" notin error.msg
    waitFor client.stop()

  test "semantic status contracts reject a different successful response":
    let privateBody = "unexpected-status-private-body"
    let probe = RestProbe(response: TransportResponse(
      status: 201, body: bytes(privateBody)))
    let client = newChronosRestClient(probe.asTransport())
    client.start()
    let raw = raw_request.initRawRequest(raw_route.httpPost, "/expects-200")
    try:
      discard waitFor client.executeJson(raw, decodeName)
      check false
    except DecodeError as error:
      check error.metadata.status == some(201)
      check error.metadata.route == some("POST /expects-200")
      check privateBody notin error.msg
    waitFor client.stop()

  test "no-content contracts reject bodies forbidden by 204 and 205":
    let privateBody = "unexpected-no-content-body"
    let probe = RestProbe()
    let client = newChronosRestClient(probe.asTransport())
    client.start()
    let raw = raw_request.initRawRequest(raw_route.httpDelete, "/expects-empty")
    for status in [204, 205]:
      probe.response = TransportResponse(
        status: status, body: bytes(privateBody))
      try:
        waitFor client.executeNoContent(
          raw, statuses = {SuccessStatus(status)})
        check false
      except DecodeError as error:
        check error.metadata.status == some(status)
        check privateBody notin error.msg
    waitFor client.stop()
