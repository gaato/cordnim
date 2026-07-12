## Secret-safe redaction for recorded requests, headers, URLs, and JSON.
##
## Recorders replace Discord's known credential fields, credential-bearing URL
## segments and headers, plus any literal values registered by the caller. A
## value hidden inside an arbitrary application string cannot be identified
## without registration; use `withSecretValues` for those values. Redaction is
## deliberately lossy once a surface is identified.

import std/[json, sets, strutils, uri]

import cordnim/core/secrets

export secrets.redactedSecret

type
  RegisteredSecretKind = object

  RedactionConfig* = object ## Names treated as credential-bearing during
    ## redaction. All comparisons are case-insensitive.
    headerNames: HashSet[string] ## Header names whose values are removed.
    jsonKeys: HashSet[string] ## JSON object keys whose values are removed.
    queryKeys: HashSet[string] ## URL query parameter names that are removed.
    pathMarkers: HashSet[string] ## Path segments after which the next segment
      ## is treated as an embedded credential.
    secretValues: seq[Secret[RegisteredSecretKind]] ## Literal application
      ## secrets kept behind a redacted representation and scrubbed wherever
      ## they appear inside otherwise non-sensitive strings.

func `$`*(config: RedactionConfig): string =
  ## Returns a value-free description; registered literals are never rendered.
  discard config
  "RedactionConfig([REDACTED])"

func repr*(config: RedactionConfig): string =
  ## Returns the same value-free description as `$` for debugging helpers.
  $config

func lowerSet(values: openArray[string]): HashSet[string] =
  for value in values:
    result.incl(value.toLowerAscii())

func copySet(values: HashSet[string]): HashSet[string] =
  result = initHashSet[string](max(2, values.len))
  for value in values:
    result.incl(value)

func copyRedaction*(config: RedactionConfig): RedactionConfig =
  ## Returns a deep value copy whose sets do not alias `config`.
  RedactionConfig(
    headerNames: config.headerNames.copySet(),
    jsonKeys: config.jsonKeys.copySet(),
    queryKeys: config.queryKeys.copySet(),
    pathMarkers: config.pathMarkers.copySet(),
    secretValues: @(config.secretValues),
  )

func defaultRedaction*(): RedactionConfig =
  ## Returns the redaction policy applied unless a caller supplies its own.
  ##
  ## It covers the credential surfaces Discord actually exposes: the bot
  ## `Authorization` header, Ed25519 request signatures, cookies, and the
  ## interaction and webhook tokens embedded in both headers and URL paths.
  RedactionConfig(
    headerNames: lowerSet([
      "authorization",
      "x-signature-ed25519",
      "x-signature-timestamp",
      "cookie",
      "set-cookie",
      "proxy-authorization",
    ]),
    jsonKeys: lowerSet([
      "token",
      "bot_token",
      "interaction_token",
      "webhook_token",
      "access_token",
      "refresh_token",
      "client_secret",
      "secret",
      "signature",
      "signature_ed25519",
      "session_id",
      "session_token",
      "password",
      "authorization",
    ]),
    queryKeys: lowerSet([
      "token",
      "bot_token",
      "interaction_token",
      "webhook_token",
      "access_token",
      "refresh_token",
      "client_secret",
      "signature",
      "code",
    ]),
    pathMarkers: lowerSet([
      "webhooks",
      "interactions",
    ]),
  )

func hardenedRedaction*(config: RedactionConfig): RedactionConfig =
  ## Returns `config` merged over Cordnim's non-optional credential defaults.
  ##
  ## Recorders use this at construction and export boundaries so a default-
  ## initialized or caller-mutated config cannot accidentally disable Discord's
  ## standard token, signature, cookie, and authorization protections.
  result = defaultRedaction()
  for value in config.headerNames:
    result.headerNames.incl(value.toLowerAscii())
  for value in config.jsonKeys:
    result.jsonKeys.incl(value.toLowerAscii())
  for value in config.queryKeys:
    result.queryKeys.incl(value.toLowerAscii())
  for value in config.pathMarkers:
    result.pathMarkers.incl(value.toLowerAscii())
  for value in config.secretValues:
    if not value.isEmpty and value notin result.secretValues:
      result.secretValues.add(value)

func withRedactedKeys*(config: RedactionConfig,
                       jsonKeys: openArray[string] = [],
                       headerNames: openArray[string] = [],
                       queryKeys: openArray[string] = [],
                       pathMarkers: openArray[string] = []): RedactionConfig =
  ## Returns a copy of `config` extended with additional case-insensitive keys.
  result = config.copyRedaction()
  for key in jsonKeys:
    result.jsonKeys.incl(key.toLowerAscii())
  for name in headerNames:
    result.headerNames.incl(name.toLowerAscii())
  for key in queryKeys:
    result.queryKeys.incl(key.toLowerAscii())
  for marker in pathMarkers:
    result.pathMarkers.incl(marker.toLowerAscii())

func withSecretValues*(config: RedactionConfig,
                       values: openArray[string]): RedactionConfig =
  ## Returns an owned policy that also scrubs the supplied literal values.
  ##
  ## Register bot tokens, session identifiers, test credentials, and other
  ## application secrets that may appear under arbitrary keys such as `content`.
  result = config.copyRedaction()
  for value in values:
    let secret = initSecret[RegisteredSecretKind](value)
    if not secret.isEmpty and secret notin result.secretValues:
      result.secretValues.add(secret)

func scrubText*(config: RedactionConfig, value: string): string =
  ## Replaces every explicitly registered literal secret inside `value`.
  result = value
  for secret in config.secretValues:
    if not secret.isEmpty:
      result = result.replace(secret.reveal(), redactedSecret)

func redactsHeader*(config: RedactionConfig, name: string): bool =
  ## Reports whether a header value would be replaced during redaction.
  name.toLowerAscii() in config.headerNames

func redactHeaderValue*(config: RedactionConfig, name, value: string): string =
  ## Returns the marker for a credential header and the value otherwise.
  if config.redactsHeader(name): redactedSecret else: config.scrubText(value)

func redactHeaders*(config: RedactionConfig,
                    headers: openArray[(string, string)]):
                    seq[(string, string)] =
  ## Returns a header copy with every credential value replaced by the marker.
  for (name, value) in headers:
    result.add((config.scrubText(name),
      config.redactHeaderValue(name, value)))

proc redactJson*(config: RedactionConfig, node: JsonNode): JsonNode =
  ## Returns a deep copy of `node` with matching object values replaced.
  ##
  ## Object keys are matched case-insensitively at every depth; arrays are
  ## traversed element by element. A nil input yields a JSON null so callers may
  ## serialize the result without a special case.
  if node.isNil:
    return newJNull()
  case node.kind
  of JObject:
    result = newJObject()
    for key, value in node:
      let safeKey = config.scrubText(key)
      if key.toLowerAscii() in config.jsonKeys:
        result[safeKey] = newJString(redactedSecret)
      else:
        result[safeKey] = config.redactJson(value)
  of JArray:
    result = newJArray()
    for value in node:
      result.add(config.redactJson(value))
  of JString:
    result = newJString(config.scrubText(node.getStr()))
  else:
    result = node.copy()

proc redactJsonText*(config: RedactionConfig, text: string): string =
  ## Redacts a JSON document supplied as text.
  ##
  ## Text that does not parse as JSON is replaced wholesale. Opaque bytes can
  ## still contain credentials even though they have no recognizable JSON key.
  var parsed: JsonNode
  try:
    parsed = parseJson(text)
  except CatchableError:
    return redactedSecret
  $config.redactJson(parsed)

proc redactUrl*(config: RedactionConfig, url: string): string =
  ## Redacts credential path segments and query values in a request URL.
  ##
  ## Discord embeds interaction and webhook tokens directly in the path, e.g.
  ## `/webhooks/{id}/{token}`; the segment following each configured marker is
  ## replaced. Query parameters named by `queryKeys` have their values removed
  ## while the parameter name is preserved for diagnostics.
  var parsed: Uri
  try:
    parsed = parseUri(url)
  except CatchableError:
    return redactedSecret
  if parsed.username.len != 0:
    parsed.username = redactedSecret
  if parsed.password.len != 0:
    parsed.password = redactedSecret
  if parsed.anchor.len != 0:
    parsed.anchor = redactedSecret
  if parsed.path.len != 0:
    var segments = parsed.path.split('/')
    # Discord tokens sit two segments after a collection marker, following the
    # resource id: `webhooks/{id}/{token}` or `interactions/{id}/{token}`. The
    # id is not a secret, so only the token segment is replaced.
    for index in 0 .. segments.high:
      let marker = try:
          decodeUrl(segments[index]).toLowerAscii()
        except CatchableError:
          segments[index].toLowerAscii()
      if marker in config.pathMarkers and
          index + 2 <= segments.high and segments[index + 2].len != 0:
        segments[index + 2] = redactedSecret
    parsed.path = segments.join("/")
  if parsed.query.len != 0:
    var rebuilt: seq[string]
    for pair in parsed.query.split('&'):
      if pair.len == 0:
        continue
      let eq = pair.find('=')
      if eq > 0:
        let key = pair[0 ..< eq]
        let decodedKey = try:
            decodeUrl(key).toLowerAscii()
          except CatchableError:
            key.toLowerAscii()
        if decodedKey in config.queryKeys:
          rebuilt.add(key & "=" & redactedSecret)
        else:
          rebuilt.add(pair)
      else:
        rebuilt.add(pair)
    parsed.query = rebuilt.join("&")
  config.scrubText($parsed)

proc redactRouteCanonical*(config: RedactionConfig,
                           canonical: string): string =
  ## Redacts a REST route identity while preserving safe route placeholders.
  ##
  ## Canonical routes use `METHOD /template #major`. Template placeholders such
  ## as `{webhook_token}` are names rather than credential values and remain
  ## visible; rendered token segments and non-numeric major parameters do not.
  let separator = canonical.find(' ')
  let candidateMethod = if separator > 0:
      canonical[0 ..< separator]
    else:
      ""
  let httpMethod = if candidateMethod in ["DELETE", "GET", "PATCH", "POST",
      "PUT"]:
      candidateMethod
    else:
      "UNKNOWN"
  var tail = if separator >= 0 and separator + 1 < canonical.len:
      canonical[separator + 1 .. ^1]
    else:
      ""
  let majorIndex = tail.rfind(" #")
  var major = ""
  if majorIndex >= 0:
    major = tail[majorIndex + 2 .. ^1]
    tail = tail[0 ..< majorIndex]
    for character in major:
      if character notin {'0' .. '9'}:
        major = redactedSecret
        break

  let queryIndex = tail.find('?')
  let path = if queryIndex < 0: tail else: tail[0 ..< queryIndex]
  var segments = path.split('/')
  for index in 0 .. segments.high:
    let marker = try:
        decodeUrl(segments[index]).toLowerAscii()
      except CatchableError:
        segments[index].toLowerAscii()
    if marker in config.pathMarkers and index + 2 <= segments.high:
      let value = segments[index + 2]
      let isPlaceholder = value.len >= 2 and value[0] == '{' and
        value[^1] == '}'
      if value.len != 0 and not isPlaceholder:
        segments[index + 2] = redactedSecret

  result = httpMethod & " " & segments.join("/")
  if queryIndex >= 0:
    let queryOnly = config.redactUrl("/?" & tail[queryIndex + 1 .. ^1])
    let safeQueryIndex = queryOnly.find('?')
    if safeQueryIndex >= 0:
      result.add(queryOnly[safeQueryIndex .. ^1])
  if major.len != 0:
    result.add(" #" & major)
  result = config.scrubText(result)
