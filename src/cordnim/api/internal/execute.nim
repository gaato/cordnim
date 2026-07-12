## Shared execution boundary for handwritten semantic REST modules.
##
## Domain modules provide a generated raw route and a semantic JSON decoder.
## This module sends the request through the central scheduler, converts HTTP
## failures with `submitChecked`, and keeps response bodies out of diagnostics.

import std/[json, options]

import chronos

import cordnim/core/errors
import cordnim/raw/request as raw_request
import cordnim/rest/[checked, chronos_driver, raw_bridge, request]

type
  JsonDecoder*[T] = proc(document: JsonNode): T {.
    nimcall, raises: [CatchableError].}
  SuccessStatus* = range[200..299] ## Successful status accepted by an
    ## operation-specific semantic decoder.

const anySuccessStatuses* = {SuccessStatus(200)..SuccessStatus(299)}
  ## Compatibility set used only by the lowest-level checked executor.

func responseText(body: openArray[byte]): string =
  result = newString(body.len)
  for index, value in body:
    result[index] = char(value)

func routeLabel(request: raw_request.RawRequest): string =
  $request.route.httpMethod & " " & request.route.pathTemplate

func decodeFailure(request: raw_request.RawRequest; message: string;
                   status = none(int)):
    ref DecodeError =
  newDiscordError(
    DecodeError,
    message,
    initDiscordFailureMeta(status = status, route = some(request.routeLabel())),
  )

proc requireStatus(request: raw_request.RawRequest;
                   response: TransportResponse;
                   statuses: set[SuccessStatus]) =
  if response.status < 200 or response.status > 299 or
      SuccessStatus(response.status) notin statuses:
    raise request.decodeFailure(
      "Discord REST response used an unexpected success status",
      some(response.status))

proc requireEmptyBody(request: raw_request.RawRequest;
                      response: TransportResponse) =
  if response.body.len != 0:
    raise request.decodeFailure(
      "Discord REST no-content response unexpectedly carried a body",
      some(response.status))

proc executeChecked*(client: ChronosRestClient;
                     raw: raw_request.RawRequest;
                     meta = defaultRequestMeta();
                     auth = darConfigured;
                     statuses = anySuccessStatuses):
                     Future[TransportResponse] {.async.} =
  ## Executes `raw` and returns one successful transport response.
  if client.isNil:
    raise newException(ValueError, "semantic REST API requires a REST client")
  let response = await client.submitChecked(raw.toRuntimeRequest(meta, auth))
  raw.requireStatus(response, statuses)
  return response

proc executeDocument*(client: ChronosRestClient;
                      raw: raw_request.RawRequest;
                      meta = defaultRequestMeta();
                      auth = darConfigured;
                      statuses: set[SuccessStatus] = {SuccessStatus(200)}):
                      Future[JsonNode] {.async.} =
  ## Executes `raw` and parses a non-empty successful JSON response.
  let response = await client.executeChecked(raw, meta, auth, statuses)
  if response.body.len == 0:
    raise raw.decodeFailure("Discord REST response body is empty")
  try:
    return parseJson(response.body.responseText())
  except CatchableError:
    raise raw.decodeFailure("Discord REST response is not valid JSON")

proc executeJson*[T](client: ChronosRestClient;
                     raw: raw_request.RawRequest;
                     decoder: JsonDecoder[T];
                     meta = defaultRequestMeta();
                     auth = darConfigured;
                     statuses: set[SuccessStatus] = {SuccessStatus(200)}):
                     Future[T] {.async.} =
  ## Executes one request and applies a semantic decoder to its JSON response.
  if decoder.isNil:
    raise newException(ValueError, "semantic REST decoder is required")
  let document = await client.executeDocument(raw, meta, auth, statuses)
  try:
    return decoder(document)
  except DecodeError:
    raise
  except CatchableError:
    raise raw.decodeFailure("Discord REST response failed semantic decoding")

proc executeOptionalJson*[T](client: ChronosRestClient;
                             raw: raw_request.RawRequest;
                             decoder: JsonDecoder[T];
                             meta = defaultRequestMeta();
                             auth = darConfigured;
                             statuses: set[SuccessStatus] =
                               {SuccessStatus(200)}):
                             Future[Option[T]] {.async.} =
  ## Decodes a successful JSON body, or returns `none` for an empty success.
  ##
  ## Discord uses this shape for endpoints whose success body depends on query
  ## flags or whether a resource was newly created.
  if decoder.isNil:
    raise newException(ValueError, "semantic REST decoder is required")
  let response = await client.executeChecked(raw, meta, auth, statuses)
  if response.status == 204 or response.status == 205:
    raw.requireEmptyBody(response)
    return none(T)
  if response.body.len == 0:
    return none(T)
  var document: JsonNode
  try:
    document = parseJson(response.body.responseText())
  except CatchableError:
    raise raw.decodeFailure("Discord REST response is not valid JSON")
  try:
    return some(decoder(document))
  except DecodeError:
    raise
  except CatchableError:
    raise raw.decodeFailure("Discord REST response failed semantic decoding")

proc executeJsonArray*[T](client: ChronosRestClient;
                          raw: raw_request.RawRequest;
                          decoder: JsonDecoder[T];
                          meta = defaultRequestMeta();
                          allowNull = false;
                          auth = darConfigured;
                          statuses: set[SuccessStatus] =
                            {SuccessStatus(200)}): Future[seq[T]] {.async.} =
  ## Executes one request and decodes each element of a JSON array.
  ##
  ## Some pinned Discord list responses admit top-level `null`; callers opt in
  ## to treating that wire value as an empty semantic collection.
  if decoder.isNil:
    raise newException(ValueError, "semantic REST decoder is required")
  let document = await client.executeDocument(raw, meta, auth, statuses)
  if document.kind == JNull and allowNull:
    return @[]
  if document.kind != JArray:
    raise raw.decodeFailure("Discord REST response must be a JSON array")
  for item in document.elems:
    try:
      result.add(decoder(item))
    except DecodeError:
      raise
    except CatchableError:
      raise raw.decodeFailure(
        "Discord REST array item failed semantic decoding")

proc executeNoContent*(client: ChronosRestClient;
                       raw: raw_request.RawRequest;
                       meta = defaultRequestMeta();
                       auth = darConfigured;
                       statuses: set[SuccessStatus] =
                         {SuccessStatus(204)}): Future[void] {.async.} =
  ## Executes a request whose successful response has no semantic body.
  let response = await client.executeChecked(raw, meta, auth, statuses)
  raw.requireEmptyBody(response)
