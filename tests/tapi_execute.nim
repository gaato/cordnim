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
    check (waitFor client.executeOptionalJson(raw, decodeName)).isNone
    probe.response = TransportResponse(
      status: 201, body: bytes("""{"name":"created"}"""))
    check (waitFor client.executeOptionalJson(raw, decodeName)) ==
      some("created")
    waitFor client.stop()
