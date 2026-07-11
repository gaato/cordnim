## Lossless descriptions of Discord HTTP routes.

import std/[options, strutils]

type
  HttpMethod* = enum ## HTTP methods emitted by Discord's stable OpenAPI schema.
    httpGet = "GET",       ## Safe retrieval operation.
    httpPost = "POST",     ## Create or action operation.
    httpPut = "PUT",       ## Idempotent replacement operation.
    httpPatch = "PATCH",   ## Partial update operation.
    httpDelete = "DELETE"  ## Deletion operation.

  RawRoute* = object ## Operation copied from the pinned Discord OpenAPI document.
    httpMethod*: HttpMethod ## HTTP method sent to Discord.
    pathTemplate*: string ## API path with `{name}` substitution markers.
    operationId*: string ## Stable OpenAPI operation identifier.
    requestSchema*: string ## Request body schema label, or empty when absent.
    responseSchema*: string ## Successful response schema label, or empty when absent.
    hasRequestBody*: bool ## Whether OpenAPI declares a request body.
    deprecated*: bool ## Whether OpenAPI marks the operation deprecated.

  RawParameter* = object ## One unencoded path-template substitution.
    name*: string ## Placeholder name without braces.
    value*: string ## Raw value to percent-encode into one path segment.

  RawRouteError* = object of ValueError ## Missing, duplicate, or unsafe raw route input.

const hexDigits = "0123456789ABCDEF"

func initRawParameter*(name, value: string): RawParameter =
  ## Creates one named path substitution; encoding occurs in `renderPath`.
  RawParameter(name: name, value: value)

func `$`*(httpMethod: HttpMethod): string =
  ## Formats the uppercase HTTP method token.
  case httpMethod
  of httpGet: "GET"
  of httpPost: "POST"
  of httpPut: "PUT"
  of httpPatch: "PATCH"
  of httpDelete: "DELETE"

func encodePathSegment*(value: string): string =
  ## Percent-encodes one path parameter without treating `/` as a separator.
  for byteValue in value:
    if byteValue in {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~'}:
      result.add byteValue
    else:
      let unsigned = ord(byteValue)
      result.add '%'
      result.add hexDigits[(unsigned shr 4) and 0x0f]
      result.add hexDigits[unsigned and 0x0f]

func parameterNames*(route: RawRoute): seq[string] =
  ## Returns placeholder names in path-template order.
  var cursor = 0
  while cursor < route.pathTemplate.len:
    let opening = route.pathTemplate.find('{', cursor)
    if opening < 0:
      break
    let closing = route.pathTemplate.find('}', opening + 1)
    if closing < 0:
      break
    result.add route.pathTemplate[opening + 1 ..< closing]
    cursor = closing + 1

func findParameter(
    parameters: openArray[RawParameter], name: string
): Option[string] =
  for parameter in parameters:
    if parameter.name == name:
      return some(parameter.value)

func renderPath*(
    route: RawRoute, parameters: openArray[RawParameter] = []
): string =
  ## Renders the route and rejects missing, duplicate, and unused parameters.
  var used = newSeq[bool](parameters.len)
  var cursor = 0

  for name in route.parameterNames:
    let opening = route.pathTemplate.find('{', cursor)
    let closing = route.pathTemplate.find('}', opening + 1)
    result.add route.pathTemplate[cursor ..< opening]

    var found = -1
    for index, parameter in parameters:
      if parameter.name == name:
        if found >= 0:
          raise newException(
            RawRouteError, "duplicate route parameter: " & name
          )
        found = index

    if found < 0:
      raise newException(RawRouteError, "missing route parameter: " & name)

    used[found] = true
    result.add encodePathSegment(parameters[found].value)
    cursor = closing + 1

  result.add route.pathTemplate[cursor .. ^1]
  for index, parameter in parameters:
    if not used[index]:
      raise newException(
        RawRouteError, "unused route parameter: " & parameter.name
      )

func rateLimitKey*(
    route: RawRoute, parameters: openArray[RawParameter] = []
): string =
  ## Builds a stable pre-bucket key while retaining Discord's major parameters.
  ## The server-provided bucket ID remains authoritative once one is observed.
  const majorParameters = [
    "channel_id", "guild_id", "webhook_id", "webhook_token"
  ]
  result = $route.httpMethod
  var cursor = 0
  for name in route.parameterNames:
    let opening = route.pathTemplate.find('{', cursor)
    let closing = route.pathTemplate.find('}', opening + 1)
    result.add route.pathTemplate[cursor ..< opening]
    if name in majorParameters:
      let value = findParameter(parameters, name)
      if value.isNone:
        raise newException(RawRouteError, "missing route parameter: " & name)
      if name == "webhook_token":
        # The webhook ID already provides a conservative provisional bucket.
        # Never put a credential into a key that may reach diagnostics.
        result.add ":webhook_token"
      else:
        result.add encodePathSegment(value.get)
    else:
      result.add ':'
      result.add name
    cursor = closing + 1
  result.add route.pathTemplate[cursor .. ^1]

func majorParameterKey*(
    route: RawRoute, parameters: openArray[RawParameter] = []): string =
  ## Returns a token-free identity for Discord's major rate-limit parameters.
  ##
  ## Webhook tokens deliberately collapse under their webhook ID. This is
  ## conservative and keeps credentials out of scheduler diagnostics.
  for name in ["channel_id", "guild_id", "webhook_id"]:
    if name in route.parameterNames:
      let value = findParameter(parameters, name)
      if value.isNone:
        raise newException(RawRouteError,
          "missing route parameter: " & name)
      if result.len != 0:
        result.add('|')
      result.add(name & '=' & encodePathSegment(value.get()))
