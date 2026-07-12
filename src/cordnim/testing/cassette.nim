## Redacted record/replay primitives for REST exchanges and Gateway events.
##
## A Cassette redacts known Discord credential fields and caller-registered
## literal secrets at capture, parse, export, and replay boundaries. Register
## application secrets with withSecretValues when they may appear under an
## arbitrary key such as content. The recorder replaces opaque REST bodies and
## stores only the length of a binary Gateway frame.

import std/[json, options, strutils]

import cordnim/gateway/close_policy
import cordnim/gateway/transport
import cordnim/rest

import ./redaction
import ./scripted_gateway
import ./scripted_rest

const
  cassetteVersion = 2
  multipartMarker = "[multipart]"

type
  RecordedRequest* = object ## Redacted snapshot of a recorded REST request.
    httpMethod*: HttpMethod ## Method taken from the route key.
    routeCanonical*: string ## Token-free canonical route identity.
    redactedPath*: string ## Request path with embedded tokens removed.
    redactedHeaders*: seq[(string, string)] ## Headers after redaction.
    bodyKind*: RestBodyKind ## Original request body representation.
    bodyLength*: Option[int64] ## Known original body length, when available.
    bodyText*: string ## Redacted JSON, a marker, or an empty body.

  RecordedResponse* = object ## Redacted snapshot of a recorded REST response.
    status*: int ## HTTP status code.
    redactedHeaders*: seq[(string, string)] ## Headers after redaction.
    bodyText*: string ## Redacted JSON, a marker, or an empty body.

  RestExchange* = object ## One recorded request/response pair.
    request*: RecordedRequest ## Redacted request side.
    response*: RecordedResponse ## Redacted response side.

  GatewayRecordKind* = enum ## Recorded Gateway event classification.
    grMessageText ## A received text message.
    grMessageBinary ## Metadata for an unreplayable binary message.
    grClose ## A peer-close event.

  GatewayRecord* = object ## One redacted recorded Gateway event.
    case kind*: GatewayRecordKind
    of grMessageText:
      text*: string ## Redacted text payload.
    of grMessageBinary:
      byteLength*: int ## Original byte count; payload bytes are never retained.
    of grClose:
      code*: uint16 ## WebSocket close code.
      reason*: string ## Empty or a fixed redaction marker.
      clean*: bool ## Whether the close frame was valid.

  Cassette* = object ## In-memory, redacted record of REST and Gateway traffic.
    redaction*: RedactionConfig ## Policy applied at every trust boundary.
    restExchanges*: seq[RestExchange] ## Recorded REST exchanges, in order.
    gatewayRecords*: seq[GatewayRecord] ## Recorded Gateway events, in order.

func initCassette*(redaction = defaultRedaction()): Cassette =
  ## Creates an empty cassette with an owned redaction policy.
  Cassette(redaction: redaction.hardenedRedaction())

proc bytesToText(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for index, value in bytes:
    result[index] = char(value)

proc textToBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for index, character in text:
    result[index] = byte(character)

proc redactStoredText(config: RedactionConfig, text: string): string =
  ## Re-redacts caller-mutable cassette fields without destroying safe markers.
  if text.len == 0 or text == redactedSecret or text == multipartMarker:
    return text
  config.redactJsonText(text)

proc sanitizeRouteCanonical(config: RedactionConfig, httpMethod: HttpMethod,
                            canonical: string): string =
  ## Preserves the documented method/template/major shape while sanitizing any
  ## caller-mutated or externally parsed value before it can be exported.
  let prefix = $httpMethod & " "
  var tail = canonical
  if tail.startsWith(prefix):
    tail = tail[prefix.len .. ^1]
  elif tail.find(' ') >= 0:
    tail = tail[tail.find(' ') + 1 .. ^1]
  config.redactRouteCanonical(prefix & tail)

proc recordRequest(cassette: Cassette, request: RawRequest): RecordedRequest =
  result.httpMethod = request.route.httpMethod
  result.routeCanonical = cassette.redaction.sanitizeRouteCanonical(
    request.route.httpMethod, request.route.canonical())
  result.redactedPath = cassette.redaction.redactUrl(request.urlPath)
  result.redactedHeaders = cassette.redaction.redactHeaders(request.headers)
  result.bodyKind = request.body.kind
  result.bodyLength = request.body.contentLength()
  case request.body.kind
  of rbMultipart:
    result.bodyText = multipartMarker
  of rbEmpty:
    discard
  of rbBytes:
    result.bodyText = redactedSecret
  of rbJson:
    result.bodyText = cassette.redaction.redactJsonText(
      bytesToText(request.body.jsonValue))

func representationDependentHeader(name: string): bool =
  name.toLowerAscii() in [
    "content-length", "content-encoding", "transfer-encoding", "etag",
    "content-md5", "content-range", "digest", "content-digest",
    "repr-digest"]

proc safeResponseHeaders(config: RedactionConfig,
                         headers: openArray[(string, string)],
                         opaqueBody = false):
                         seq[(string, string)] =
  ## A redacted/re-serialized body no longer matches representation validators.
  for (name, value) in headers:
    let lowerName = name.toLowerAscii()
    if not name.representationDependentHeader() and
        not (opaqueBody and lowerName == "content-type"):
      result.add((config.scrubText(name),
        config.redactHeaderValue(name, value)))

proc recordResponse(cassette: Cassette,
                    response: TransportResponse): RecordedResponse =
  result.status = response.status
  if response.body.len != 0:
    result.bodyText = cassette.redaction.redactJsonText(
      bytesToText(response.body))
  result.redactedHeaders = cassette.redaction.safeResponseHeaders(
    response.headers, result.bodyText == redactedSecret)

proc recordRestExchange*(cassette: var Cassette, request: RawRequest,
                         response: TransportResponse) =
  ## Records one REST request/response pair without retaining credential bytes.
  cassette.restExchanges.add(RestExchange(
    request: cassette.recordRequest(request),
    response: cassette.recordResponse(response),
  ))

proc recordGatewayEvent*(cassette: var Cassette,
                         event: GatewayTransportEvent) =
  ## Records a text/close event safely, or only the length of a binary frame.
  case event.kind
  of gatewayMessageReceived:
    case event.message.kind
    of gatewayTextMessage:
      cassette.gatewayRecords.add(GatewayRecord(
        kind: grMessageText,
        text: cassette.redaction.redactJsonText(
          bytesToText(event.message.data)),
      ))
    of gatewayBinaryMessage:
      cassette.gatewayRecords.add(GatewayRecord(
        kind: grMessageBinary,
        byteLength: event.message.data.len,
      ))
  of gatewayTransportClosed:
    cassette.gatewayRecords.add(GatewayRecord(
      kind: grClose,
      code: event.closeInfo.code.toUint16(),
      reason: if event.closeInfo.reason.len == 0: "" else: redactedSecret,
      clean: event.closeInfo.clean,
    ))

proc safeHeaders(config: RedactionConfig,
                 headers: openArray[(string, string)]): seq[(string, string)] =
  config.redactHeaders(headers)

proc `%`(headers: seq[(string, string)]): JsonNode =
  result = newJArray()
  for (name, value) in headers:
    result.add(%*{"name": name, "value": value})

proc toHeaders(node: JsonNode, config: RedactionConfig): seq[(string, string)] =
  if node.isNil:
    return
  if node.kind != JArray:
    raise newException(ValueError, "cassette headers must be an array")
  var headers: seq[(string, string)]
  for item in node:
    if item.kind != JObject or not item.hasKey("name") or
        not item.hasKey("value"):
      raise newException(ValueError, "cassette header entry is malformed")
    headers.add((item["name"].getStr(), item["value"].getStr()))
  config.safeHeaders(headers)

proc toJson*(cassette: Cassette): JsonNode =
  ## Serializes a cassette after re-redacting all caller-mutable fields.
  let config = cassette.redaction.hardenedRedaction()
  result = %*{
    "version": cassetteVersion,
    "rest": newJArray(),
    "gateway": newJArray(),
  }
  for exchange in cassette.restExchanges:
    let requestRoute = config.sanitizeRouteCanonical(
      exchange.request.httpMethod, exchange.request.routeCanonical)
    let responseBody = config.redactStoredText(exchange.response.bodyText)
    result["rest"].add(%*{
      "request": {
        "method": $exchange.request.httpMethod,
        "route": requestRoute,
        "path": config.redactUrl(exchange.request.redactedPath),
        "headers": %config.safeHeaders(exchange.request.redactedHeaders),
        "body_kind": $exchange.request.bodyKind,
        "body_length": (if exchange.request.bodyLength.isSome:
            %exchange.request.bodyLength.get()
          else:
            newJNull()),
        "body": config.redactStoredText(exchange.request.bodyText),
      },
      "response": {
        "status": exchange.response.status,
        "headers": %config.safeResponseHeaders(
          exchange.response.redactedHeaders,
          responseBody == redactedSecret),
        "body": responseBody,
      },
    })
  for record in cassette.gatewayRecords:
    case record.kind
    of grMessageText:
      result["gateway"].add(%*{
        "kind": "message_text",
        "text": config.redactStoredText(record.text),
      })
    of grMessageBinary:
      result["gateway"].add(%*{
        "kind": "message_binary",
        "length": max(0, record.byteLength),
      })
    of grClose:
      result["gateway"].add(%*{
        "kind": "close",
        "code": int(record.code),
        "reason": if record.reason.len == 0: "" else: redactedSecret,
        "clean": record.clean,
      })

func parseMethod(name: string): HttpMethod =
  case name
  of "DELETE": hmDelete
  of "GET": hmGet
  of "PATCH": hmPatch
  of "POST": hmPost
  of "PUT": hmPut
  else:
    raise newException(ValueError, "unknown HTTP method in cassette: " & name)

func parseBodyKind(name: string): RestBodyKind =
  case name
  of "rbEmpty": rbEmpty
  of "rbBytes": rbBytes
  of "rbJson": rbJson
  of "rbMultipart": rbMultipart
  else:
    raise newException(ValueError,
      "unknown REST body kind in cassette: " & name)

proc parseCassette*(node: JsonNode,
                    redaction = defaultRedaction()): Cassette =
  ## Parses untrusted cassette JSON and sanitizes every persisted text field.
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "cassette JSON must be an object")
  if not node.hasKey("version") or node["version"].getInt() != cassetteVersion:
    raise newException(ValueError, "unsupported cassette version")
  result = initCassette(redaction)
  let config = result.redaction
  try:
    if node.hasKey("rest"):
      if node["rest"].kind != JArray:
        raise newException(ValueError, "cassette rest field must be an array")
      for exchange in node["rest"]:
        let request = exchange["request"]
        let response = exchange["response"]
        let httpMethod = parseMethod(request["method"].getStr())
        let bodyKind = parseBodyKind(request["body_kind"].getStr())
        var bodyLength = none(int64)
        if request.hasKey("body_length") and
            request["body_length"].kind != JNull:
          let length = request["body_length"].getBiggestInt()
          if length < 0:
            raise newException(ValueError,
              "cassette request body length cannot be negative")
          bodyLength = some(int64(length))
        let status = response["status"].getInt()
        if status < 100 or status > 599:
          raise newException(ValueError, "cassette HTTP status is out of range")
        let responseBody = config.redactStoredText(response["body"].getStr())
        result.restExchanges.add(RestExchange(
          request: RecordedRequest(
            httpMethod: httpMethod,
            routeCanonical: config.sanitizeRouteCanonical(
              httpMethod, request["route"].getStr()),
            redactedPath: config.redactUrl(request["path"].getStr()),
            redactedHeaders: toHeaders(request{"headers"}, config),
            bodyKind: bodyKind,
            bodyLength: bodyLength,
            bodyText: config.redactStoredText(request["body"].getStr()),
          ),
          response: RecordedResponse(
            status: status,
            redactedHeaders: config.safeResponseHeaders(
              toHeaders(response{"headers"}, config),
              responseBody == redactedSecret),
            bodyText: responseBody,
          ),
        ))
    if node.hasKey("gateway"):
      if node["gateway"].kind != JArray:
        raise newException(ValueError,
          "cassette gateway field must be an array")
      for record in node["gateway"]:
        case record["kind"].getStr()
        of "message_text":
          result.gatewayRecords.add(GatewayRecord(
            kind: grMessageText,
            text: config.redactStoredText(record["text"].getStr()),
          ))
        of "message_binary":
          let byteLength = record["length"].getInt()
          if byteLength < 0:
            raise newException(ValueError,
              "cassette binary frame length cannot be negative")
          result.gatewayRecords.add(GatewayRecord(
            kind: grMessageBinary,
            byteLength: byteLength,
          ))
        of "close":
          let code = record["code"].getInt()
          if code < 1000 or code > 4999:
            raise newException(ValueError,
              "cassette Gateway close code is out of range")
          let reason = record["reason"].getStr()
          result.gatewayRecords.add(GatewayRecord(
            kind: grClose,
            code: uint16(code),
            reason: if reason.len == 0: "" else: redactedSecret,
            clean: record["clean"].getBool(),
          ))
        else:
          raise newException(ValueError,
            "unknown gateway record kind in cassette")
  except ValueError:
    raise
  except CatchableError as error:
    raise newException(ValueError, "malformed cassette JSON: " & error.msg)

proc replayRestTransport*(cassette: Cassette): ScriptedRestTransport =
  ## Builds a matcher-backed script from recorded, redacted REST exchanges.
  ##
  ## Replay verifies the method, canonical route, redacted path and header
  ## multiset, plus the body representation. JSON bodies use structural matching.
  ## Opaque and multipart bodies use their known byte length because the cassette
  ## does not retain their bytes.
  let config = cassette.redaction.hardenedRedaction()
  result = newScriptedRestTransport(config)
  for exchange in cassette.restExchanges:
    let httpMethod = exchange.request.httpMethod
    let route = config.sanitizeRouteCanonical(
      httpMethod, exchange.request.routeCanonical)
    let path = config.redactUrl(exchange.request.redactedPath)
    let requestBody = config.redactStoredText(exchange.request.bodyText)
    var bodyJson = none(JsonNode)
    if requestBody.len != 0 and requestBody != redactedSecret and
        requestBody != multipartMarker:
      try:
        bodyJson = some(parseJson(requestBody))
      except CatchableError:
        discard
    let matcher = restMatcher(
      httpMethod = some(httpMethod),
      redactedRouteCanonical = some(route),
      redactedUrlPath = some(path),
      bodyKind = some(exchange.request.bodyKind),
      bodyLength = if exchange.request.bodyKind in {rbBytes, rbMultipart}:
          exchange.request.bodyLength
        else:
          none(int64),
      redactedHeadersExact = some(
        config.safeHeaders(exchange.request.redactedHeaders)),
      redactedBodyJson = bodyJson,
    )
    let status = exchange.response.status
    if status < 100 or status > 599:
      raise newException(ValueError, "cassette HTTP status is out of range")
    let responseBody = config.redactStoredText(exchange.response.bodyText)
    result.expectRequest(transportResponse(
      status,
      textToBytes(responseBody),
      config.safeResponseHeaders(exchange.response.redactedHeaders,
        responseBody == redactedSecret),
    ), matcher)

proc replayGatewayDriver*(cassette: Cassette): ScriptedGatewayDriver =
  ## Builds a scripted driver for safely replayable text and close events.
  ##
  ## A cassette containing a binary frame is rejected because only its length is
  ## retained; inventing payload bytes would silently test different behavior.
  for record in cassette.gatewayRecords:
    if record.kind == grMessageBinary:
      raise newException(ValueError,
        "binary Gateway cassette records are metadata-only and cannot replay")
  let config = cassette.redaction.hardenedRedaction()
  result = newScriptedGatewayDriver(config)
  for record in cassette.gatewayRecords:
    case record.kind
    of grMessageText:
      result.queueMessageText(config.redactStoredText(record.text))
    of grMessageBinary:
      discard
    of grClose:
      if record.code < 1000'u16 or record.code > 4999'u16:
        raise newException(ValueError,
          "cassette Gateway close code is out of range")
      result.queueClose(GatewayCloseCode(record.code),
        if record.reason.len == 0: "" else: redactedSecret,
        record.clean)
