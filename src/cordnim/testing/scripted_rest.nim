## Deterministic scripted implementation of the REST transport contract.
##
## A `ScriptedRestTransport` satisfies `cordnim/rest`'s `RestTransport` callback
## without any network I/O. A test queues expected requests paired with canned
## `TransportResponse` values or injected failures; each dispatched request is
## matched against the head of the queue, recorded in a sanitized form, and
## answered with the scripted result. Unexpected requests and unconsumed
## responses are surfaced through explicit assertions at teardown.
##
## Recorded requests redact known Discord credential fields and literal values
## registered with withSecretValues. Diagnostics contain redacted routes and
## value-free JSON mismatch paths. The callback completes each response in the
## same event-loop turn; timing tests should supply a custom transport.

import std/[json, options, strutils]

import chronos

import cordnim/core/errors as cordErrors
import cordnim/rest

import ./canonical_json
import ./redaction

type
  SanitizedRequest* = object ## Redacted snapshot of one observed REST request.
    httpMethod*: HttpMethod ## Method taken from the route key.
    routeCanonical*: string ## Token-free canonical route identity.
    redactedPath*: string ## Request path with embedded tokens removed.
    redactedHeaders*: seq[(string, string)] ## Caller headers after redaction.
    bodyKind*: RestBodyKind ## Body representation classification.
    bodyBytes*: seq[byte] ## Redacted JSON bytes or a redaction marker; empty
      ## for an empty or streamed multipart body.
    bodyRedacted*: bool ## Whether the observed body was replaced or rewritten.
    bodyLength*: Option[int64] ## Known wire body length when available.

  RestMatcher* = object ## Optional expectations checked against a request.
    ## Every field left at its default matches any request.
    httpMethod*: Option[HttpMethod] ## Required HTTP method.
    templatePath*: Option[string] ## Required route template path.
    routeCanonical*: Option[string] ## Required canonical route identity.
    redactedRouteCanonical*: Option[string] ## Required canonical identity after
      ## applying the transport's redaction policy; used by cassette replay.
    urlPath*: Option[string] ## Required exact rendered URL path.
    redactedUrlPath*: Option[string] ## Required path after applying the
      ## transport's redaction policy; intended for cassette replay.
    bodyKind*: Option[RestBodyKind] ## Required body representation kind.
    bodyLength*: Option[int64] ## Required known body length, when supplied.
    redactedHeadersExact*: Option[seq[(string, string)]] ## Required complete
      ## header multiset after applying the transport's redaction policy.
    requiredHeaders*: seq[(string, string)] ## Headers that must be present.
    body*: Option[seq[byte]] ## Required exact static body bytes.
    bodyJson*: Option[JsonNode] ## Required value-equal JSON body.
    redactedBodyJson*: Option[JsonNode] ## Required JSON after both expected
      ## and actual values pass through the redaction policy.

  RestStepKind = enum
    rskRespond
    rskFail

  ScriptedRestStep = object
    matcher: RestMatcher
    case kind: RestStepKind
    of rskRespond:
      response: TransportResponse
    of rskFail:
      error: ref CatchableError

  ScriptedRestTransport* = ref object ## Mutable queue and observation log for a
    ## scripted REST transport.
    steps: seq[ScriptedRestStep]
    cursor: int
    observed: seq[SanitizedRequest]
    failures: seq[string]
    redaction: RedactionConfig

func newScriptedRestTransport*(
    redaction = defaultRedaction()): ScriptedRestTransport =
  ## Creates an empty scripted transport with a redaction policy.
  ScriptedRestTransport(redaction: redaction.hardenedRedaction())

func copyBytes(value: openArray[byte]): seq[byte] =
  result = newSeq[byte](value.len)
  for index, item in value:
    result[index] = item

func copyHeaders(value: openArray[(string, string)]): seq[(string, string)] =
  for item in value:
    result.add(item)

func copyMatcher(matcher: RestMatcher): RestMatcher =
  result = matcher
  result.requiredHeaders = matcher.requiredHeaders.copyHeaders()
  if matcher.body.isSome:
    result.body = some(matcher.body.get().copyBytes())
  if matcher.redactedHeadersExact.isSome:
    result.redactedHeadersExact = some(
      matcher.redactedHeadersExact.get().copyHeaders())
  if matcher.bodyJson.isSome:
    result.bodyJson = some(matcher.bodyJson.get().copy())
  if matcher.redactedBodyJson.isSome:
    result.redactedBodyJson = some(matcher.redactedBodyJson.get().copy())

func copyResponse(response: TransportResponse): TransportResponse =
  result = response
  result.headers = response.headers.copyHeaders()
  result.body = response.body.copyBytes()

func restMatcher*(httpMethod = none(HttpMethod),
                  templatePath = none(string),
                  routeCanonical = none(string),
                  redactedRouteCanonical = none(string),
                  urlPath = none(string),
                  redactedUrlPath = none(string),
                  bodyKind = none(RestBodyKind),
                  bodyLength = none(int64),
                  redactedHeadersExact = none(seq[(string, string)]),
                  requiredHeaders: openArray[(string, string)] = [],
                  body = none(seq[byte]),
                  bodyJson = none(JsonNode),
                  redactedBodyJson = none(JsonNode)): RestMatcher =
  ## Builds a matcher; omitted fields accept any request.
  RestMatcher(
    httpMethod: httpMethod,
    templatePath: templatePath,
    routeCanonical: routeCanonical,
    redactedRouteCanonical: redactedRouteCanonical,
    urlPath: urlPath,
    redactedUrlPath: redactedUrlPath,
    bodyKind: bodyKind,
    bodyLength: bodyLength,
    redactedHeadersExact: if redactedHeadersExact.isSome:
        some(redactedHeadersExact.get().copyHeaders())
      else:
        none(seq[(string, string)]),
    requiredHeaders: requiredHeaders.copyHeaders(),
    body: if body.isSome: some(body.get().copyBytes()) else: none(seq[byte]),
    bodyJson: if bodyJson.isSome: some(bodyJson.get().copy()) else: none(JsonNode),
    redactedBodyJson: if redactedBodyJson.isSome:
        some(redactedBodyJson.get().copy())
      else:
        none(JsonNode),
  )

func matchMethod*(httpMethod: HttpMethod): RestMatcher =
  ## Builds a matcher requiring only a specific HTTP method.
  restMatcher(httpMethod = some(httpMethod))

func matchRoute*(routeCanonical: string): RestMatcher =
  ## Builds a matcher requiring a specific canonical route identity.
  restMatcher(routeCanonical = some(routeCanonical))

proc expectRequest*(transport: ScriptedRestTransport,
                    response: TransportResponse,
                    matcher = RestMatcher()) =
  ## Queues one canned response to answer the next matching request.
  if transport.isNil:
    raise newException(ValueError, "scripted REST transport is required")
  transport.steps.add(ScriptedRestStep(
    kind: rskRespond,
    matcher: matcher.copyMatcher(),
    response: response.copyResponse()))

proc expectFailure*(transport: ScriptedRestTransport,
                    error: ref CatchableError,
                    matcher = RestMatcher()) =
  ## Queues one injected failure for the next matching request.
  ##
  ## The scheduler classifies `TransportError` as retryable, so passing a
  ## `TransportError` exercises the automatic-retry path deterministically.
  if error.isNil:
    raise newException(ValueError, "scripted failure must not be nil")
  if transport.isNil:
    raise newException(ValueError, "scripted REST transport is required")
  transport.steps.add(ScriptedRestStep(
    kind: rskFail, matcher: matcher.copyMatcher(), error: error))

func encoded(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for index, value in text:
    result[index] = byte(value)

proc bodyText(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for index, value in bytes:
    result[index] = char(value)

func headersEqual(left, right: openArray[(string, string)]): bool =
  ## Header order is irrelevant, while duplicate name-value pairs remain exact.
  if left.len != right.len:
    return false
  var matched = newSeq[bool](right.len)
  for (leftName, leftValue) in left:
    var found = false
    for index, (rightName, rightValue) in right:
      if not matched[index] and leftName.cmpIgnoreCase(rightName) == 0 and
          leftValue == rightValue:
        matched[index] = true
        found = true
        break
    if not found:
      return false
  true

proc sanitize(transport: ScriptedRestTransport,
              request: RawRequest): SanitizedRequest =
  result.httpMethod = request.route.httpMethod
  result.routeCanonical = transport.redaction.redactRouteCanonical(
    request.route.canonical())
  result.redactedPath = transport.redaction.redactUrl(request.urlPath)
  result.redactedHeaders = transport.redaction.redactHeaders(request.headers)
  result.bodyKind = request.body.kind
  result.bodyLength = request.body.contentLength()
  # Access variant fields directly; the public `bodyBytes` raises for multipart,
  # which would leak a `ValueError` effect into the `raises: []` transport.
  case request.body.kind
  of rbEmpty, rbMultipart:
    discard
  of rbBytes:
    result.bodyBytes = redactedSecret.encoded()
    result.bodyRedacted = true
  of rbJson:
    let original = bodyText(request.body.jsonValue)
    let safe = transport.redaction.redactJsonText(original)
    result.bodyBytes = safe.encoded()
    result.bodyRedacted = safe != original

func describe(sanitized: SanitizedRequest): string =
  $sanitized.httpMethod & " " & sanitized.redactedPath &
    " (route " & sanitized.routeCanonical & ")"

func headerValue(headers: openArray[(string, string)],
                 name: string): Option[string] =
  for (key, value) in headers:
    if key.cmpIgnoreCase(name) == 0:
      return some(value)
  none(string)

proc matchRequest(transport: ScriptedRestTransport, matcher: RestMatcher,
                  request: RawRequest, sanitized: SanitizedRequest): string =
  ## Returns "" when the request satisfies the matcher, else a redacted reason.
  if matcher.httpMethod.isSome and
      matcher.httpMethod.get() != request.route.httpMethod:
    return "expected method " & $matcher.httpMethod.get() & ", got " &
      $request.route.httpMethod
  if matcher.templatePath.isSome and
      matcher.templatePath.get() != request.route.templatePath:
    return "expected template path " & matcher.templatePath.get() &
      ", got " & request.route.templatePath
  if matcher.routeCanonical.isSome and
      matcher.routeCanonical.get() != request.route.canonical():
    return "request route did not match the expected canonical route"
  if matcher.redactedRouteCanonical.isSome and
      matcher.redactedRouteCanonical.get() != sanitized.routeCanonical:
    return "redacted request route did not match the expected route"
  if matcher.urlPath.isSome and matcher.urlPath.get() != request.urlPath:
    # Compare against the raw path but never echo it; the token would leak.
    return "request path did not match the expected path (redacted: " &
      sanitized.redactedPath & ")"
  if matcher.redactedUrlPath.isSome and
      matcher.redactedUrlPath.get() != sanitized.redactedPath:
    return "redacted request path did not match the expected path"
  if matcher.bodyKind.isSome and matcher.bodyKind.get() != request.body.kind:
    return "request body kind did not match the expected representation"
  if matcher.bodyLength.isSome:
    let length = request.body.contentLength()
    if length.isNone or length.get() != matcher.bodyLength.get():
      return "request body length did not match the expected length"
  if matcher.redactedHeadersExact.isSome:
    let actualHeaders = transport.redaction.redactHeaders(request.headers)
    if not headersEqual(matcher.redactedHeadersExact.get(), actualHeaders):
      return "redacted request headers did not match the recorded headers"
  for (name, value) in matcher.requiredHeaders:
    let actual = request.headers.headerValue(name)
    if actual.isNone:
      return "missing required header " & name
    if actual.get() != value:
      return "header " & name & " did not match its expected value"
  if matcher.body.isSome:
    if request.body.kind == rbMultipart:
      return "cannot byte-match a streamed multipart body"
    let actual = case request.body.kind
      of rbEmpty: @[]
      of rbBytes: request.body.bytesValue
      of rbJson: request.body.jsonValue
      of rbMultipart: @[]
    if matcher.body.get() != actual:
      return "request body bytes did not match the expected body"
  if matcher.bodyJson.isSome or matcher.redactedBodyJson.isSome:
    if request.body.kind == rbMultipart:
      return "cannot JSON-match a streamed multipart body"
    let actualBytes = case request.body.kind
      of rbEmpty: @[]
      of rbBytes: request.body.bytesValue
      of rbJson: request.body.jsonValue
      of rbMultipart: @[]
    var parsed: JsonNode
    try:
      parsed = parseJson(bodyText(actualBytes))
    except CatchableError:
      return "request body was not valid JSON"
    let expected = if matcher.redactedBodyJson.isSome:
        transport.redaction.redactJson(matcher.redactedBodyJson.get())
      else:
        matcher.bodyJson.get()
    let actual = if matcher.redactedBodyJson.isSome:
        transport.redaction.redactJson(parsed)
      else:
        parsed
    let path = jsonMismatchPath(expected, actual)
    if path.len != 0:
      return "request body JSON mismatch at " & path
  ""

proc completedResponse(response: TransportResponse):
                       Future[TransportResponse] {.raises: [].} =
  result = newFuture[TransportResponse]("cordnim.testing.scripted-rest")
  result.complete(response)

proc failedResponse(error: ref CatchableError):
                    Future[TransportResponse] {.raises: [].} =
  result = newFuture[TransportResponse]("cordnim.testing.scripted-rest")
  result.fail(error)

proc handleRequest(transport: ScriptedRestTransport,
                   request: RawRequest): Future[TransportResponse] {.
                   gcsafe, raises: [].} =
  let sanitized = transport.sanitize(request)
  transport.observed.add(sanitized)
  if transport.cursor >= transport.steps.len:
    transport.failures.add("unexpected REST request: " & sanitized.describe())
    return failedResponse(cordErrors.newDiscordError(
      cordErrors.ValidationError, "unexpected scripted REST request"))
  let step = transport.steps[transport.cursor]
  inc transport.cursor
  let mismatch = transport.matchRequest(step.matcher, request, sanitized)
  if mismatch.len != 0:
    transport.failures.add("REST request mismatch (" & sanitized.describe() &
      "): " & mismatch)
    return failedResponse(cordErrors.newDiscordError(
      cordErrors.ValidationError, "scripted REST request did not match"))
  case step.kind
  of rskRespond:
    completedResponse(step.response)
  of rskFail:
    failedResponse(step.error)

proc asRestTransport*(transport: ScriptedRestTransport): RestTransport =
  ## Returns the `RestTransport` callback backed by this scripted transport.
  ##
  ## The callback records and answers requests on the same instance, so counts
  ## and assertions observe every dispatch made through it.
  if transport.isNil:
    raise newException(ValueError, "scripted REST transport is required")
  result = proc(request: RawRequest): Future[TransportResponse] {.
      gcsafe, raises: [].} =
    transport.handleRequest(request)

func pendingCount*(transport: ScriptedRestTransport): int =
  ## Returns the number of queued responses not yet consumed.
  transport.steps.len - transport.cursor

func observedCount*(transport: ScriptedRestTransport): int =
  ## Returns the number of requests dispatched through the transport.
  transport.observed.len

func observedRequests*(transport: ScriptedRestTransport): seq[SanitizedRequest] =
  ## Returns an owned copy of the sanitized, in-order observation log.
  for observed in transport.observed:
    var copied = observed
    copied.redactedHeaders = observed.redactedHeaders.copyHeaders()
    copied.bodyBytes = observed.bodyBytes.copyBytes()
    result.add(copied)

func recordedFailures*(transport: ScriptedRestTransport): seq[string] =
  ## Returns an owned copy of diagnostics for unexpected or mismatched requests.
  for failure in transport.failures:
    result.add(failure)

func satisfied*(transport: ScriptedRestTransport): bool =
  ## Reports whether every response was consumed and no failure was recorded.
  transport.pendingCount == 0 and transport.failures.len == 0

proc assertNoPending*(transport: ScriptedRestTransport) =
  ## Asserts that no queued response was left unconsumed.
  if transport.pendingCount != 0:
    raise newException(AssertionDefect,
      $transport.pendingCount & " scripted REST responses were never consumed")

proc assertNoFailures*(transport: ScriptedRestTransport) =
  ## Asserts that no unexpected or mismatched request was observed.
  if transport.failures.len != 0:
    raise newException(AssertionDefect,
      "scripted REST transport recorded failures: " &
      transport.failures.join("; "))

proc assertSatisfied*(transport: ScriptedRestTransport) =
  ## Asserts both that all responses were consumed and no failure was recorded.
  transport.assertNoFailures()
  transport.assertNoPending()

proc transportResponse*(status: int,
                        body: sink seq[byte] = @[],
                        headers: openArray[(string, string)] = []):
                        TransportResponse =
  ## Builds a `TransportResponse` with parsed rate-limit facts for scripting.
  TransportResponse(
    status: status,
    headers: @headers,
    body: body,
    rateLimit: parseRateLimitUpdate(status, headers, body),
  )

proc jsonResponse*(status: int, document: JsonNode,
                   headers: openArray[(string, string)] = []):
                   TransportResponse =
  ## Builds a JSON `TransportResponse` from a document and optional headers.
  let encoded = $document
  var body = newSeq[byte](encoded.len)
  for index, character in encoded:
    body[index] = byte(character)
  var merged = @[("Content-Type", "application/json")]
  merged.add(headers)
  transportResponse(status, body, merged)
