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

type JsonDecoder*[T] = proc(document: JsonNode): T {.
  nimcall, raises: [CatchableError].}

func responseText(body: openArray[byte]): string =
  result = newString(body.len)
  for index, value in body:
    result[index] = char(value)

func routeLabel(request: raw_request.RawRequest): string =
  $request.route.httpMethod & " " & request.route.pathTemplate

func decodeFailure(request: raw_request.RawRequest; message: string):
    ref DecodeError =
  newDiscordError(
    DecodeError,
    message,
    initDiscordFailureMeta(route = some(request.routeLabel())),
  )

proc executeChecked*(client: ChronosRestClient;
                     raw: raw_request.RawRequest;
                     meta = defaultRequestMeta()):
                     Future[TransportResponse] {.async.} =
  ## Executes `raw` and returns one successful transport response.
  if client.isNil:
    raise newException(ValueError, "semantic REST API requires a REST client")
  return await client.submitChecked(raw.toRuntimeRequest(meta))

proc executeDocument*(client: ChronosRestClient;
                      raw: raw_request.RawRequest;
                      meta = defaultRequestMeta()): Future[JsonNode] {.async.} =
  ## Executes `raw` and parses a non-empty successful JSON response.
  let response = await client.executeChecked(raw, meta)
  if response.body.len == 0:
    raise raw.decodeFailure("Discord REST response body is empty")
  try:
    return parseJson(response.body.responseText())
  except CatchableError:
    raise raw.decodeFailure("Discord REST response is not valid JSON")

proc executeJson*[T](client: ChronosRestClient;
                     raw: raw_request.RawRequest;
                     decoder: JsonDecoder[T];
                     meta = defaultRequestMeta()): Future[T] {.async.} =
  ## Executes one request and applies a semantic decoder to its JSON response.
  if decoder.isNil:
    raise newException(ValueError, "semantic REST decoder is required")
  let document = await client.executeDocument(raw, meta)
  try:
    return decoder(document)
  except DecodeError:
    raise
  except CatchableError:
    raise raw.decodeFailure("Discord REST response failed semantic decoding")

proc executeOptionalJson*[T](client: ChronosRestClient;
                             raw: raw_request.RawRequest;
                             decoder: JsonDecoder[T];
                             meta = defaultRequestMeta()):
                             Future[Option[T]] {.async.} =
  ## Decodes a successful JSON body, or returns `none` for an empty success.
  ##
  ## Discord uses this shape for endpoints whose success body depends on query
  ## flags or whether a resource was newly created.
  if decoder.isNil:
    raise newException(ValueError, "semantic REST decoder is required")
  let response = await client.executeChecked(raw, meta)
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
                          allowNull = false): Future[seq[T]] {.async.} =
  ## Executes one request and decodes each element of a JSON array.
  ##
  ## Some pinned Discord list responses admit top-level `null`; callers opt in
  ## to treating that wire value as an empty semantic collection.
  if decoder.isNil:
    raise newException(ValueError, "semantic REST decoder is required")
  let document = await client.executeDocument(raw, meta)
  if document.kind == JNull and allowNull:
    return @[]
  if document.kind != JArray:
    raise raw.decodeFailure("Discord REST response must be a JSON array")
  for item in document:
    try:
      result.add(decoder(item))
    except DecodeError:
      raise
    except CatchableError:
      raise raw.decodeFailure(
        "Discord REST array item failed semantic decoding")

proc executeNoContent*(client: ChronosRestClient;
                       raw: raw_request.RawRequest;
                       meta = defaultRequestMeta()): Future[void] {.async.} =
  ## Executes a request whose successful response has no semantic body.
  discard await client.executeChecked(raw, meta)
