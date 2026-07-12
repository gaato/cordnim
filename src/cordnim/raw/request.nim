## Generic request and response values for raw endpoints and escape hatches.

import std/[json, strutils, uri]

import ./route

type
  RawNameValue* = object ## One ordered query or header name-value pair.
    name*: string ## Query parameter or header name.
    value*: string ## Unredacted protocol value; callers must protect secrets.

  RawRequest* = object ## Fully rendered request accepted by the REST transport.
    route*: RawRoute ## Schema metadata and rate-limit identity.
    path*: string ## Rendered absolute API path.
    majorParameter*: string ## Token-free major rate-limit partition key.
    query*: seq[RawNameValue] ## Ordered query parameters.
    headers*: seq[RawNameValue] ## Request-specific headers.
    body*: JsonNode ## JSON request body, or nil when absent.

  RawResponse* = object ## Uninterpreted HTTP response returned by the
    ## transport.
    status*: int ## HTTP status code.
    headers*: seq[RawNameValue] ## Response headers, including rate-limit
      ## metadata.
    body*: JsonNode ## Parsed JSON body, or nil when no JSON was returned.

func initRawNameValue*(name, value: string): RawNameValue =
  ## Creates one ordered query or header pair.
  RawNameValue(name: name, value: value)

proc initRawRequest*(
    route: RawRoute,
    parameters: openArray[RawParameter] = [],
    body: JsonNode = nil
): RawRequest =
  ## Renders a generated route with checked path substitutions.
  RawRequest(
    route: route,
    path: route.renderPath(parameters),
    majorParameter: route.majorParameterKey(parameters),
    body: body
  )

proc initRawRequest*(
    httpMethod: HttpMethod,
    path: string,
    body: JsonNode = nil,
    operationId = "raw.escape_hatch"
): RawRequest =
  ## Creates a request for a stable endpoint not yet present in the snapshot.
  if path.len == 0 or path[0] != '/' or "://" in path:
    raise newException(
      RawRouteError, "raw request path must be an absolute API path"
    )
  let route = RawRoute(
    httpMethod: httpMethod,
    pathTemplate: path,
    operationId: operationId,
    requestSchema: "",
    responseSchema: "",
    hasRequestBody: not body.isNil,
    deprecated: false
  )
  RawRequest(route: route, path: path, body: body)

proc addQuery*(request: var RawRequest, name, value: string) =
  ## Appends one query parameter without silently replacing prior values.
  request.query.add(initRawNameValue(name, value))

func renderedPath*(request: RawRequest): string =
  ## Returns the API path with ordered, percent-encoded query parameters.
  result = request.path
  if request.query.len == 0:
    return
  var pairs: seq[(string, string)]
  for item in request.query:
    pairs.add((item.name, item.value))
  result.add('?')
  result.add(encodeQuery(pairs, usePlus = false, omitEq = false))

proc setHeader*(request: var RawRequest, name, value: string) =
  ## Replaces a header case-insensitively, or appends it when absent.
  for header in request.headers.mitems:
    if cmpIgnoreCase(header.name, name) == 0:
      header.value = value
      return
  request.headers.add(initRawNameValue(name, value))

func `$`*(request: RawRequest): string =
  ## Deliberately omits all caller-controlled route and payload fields. Discord
  ## webhook and interaction tokens can appear outside an Authorization header,
  ## including in a raw escape hatch's operation identifier.
  $request.route.httpMethod & " [raw request]"

func repr*(request: RawRequest): string =
  ## Uses the same credential-free representation as `$`.
  $request

proc `%`*(request: RawRequest): JsonNode =
  ## Serializes only the credential-free diagnostic representation.
  newJString($request)

proc toJsonHook*(request: RawRequest): JsonNode =
  ## Keeps `std/jsonutils` from traversing rendered request fields.
  %request
