## Transport-neutral REST request metadata.
##
## The scheduler uses integer monotonic milliseconds so it can be tested with a
## fake clock. The Chronos adapter is the only layer that converts `Moment` to
## this representation.
##
## Request bodies are explicit: empty, replayable bytes, encoded JSON, or
## source-backed multipart. The scheduler retains this representation across
## attempts and refuses to retry multipart bodies containing a non-replayable
## source.

import std/[json, options, strutils, uri]

import ./multipart

type
  MonoMillis* = distinct int64 ## Monotonic milliseconds used for deadlines
    ## and scheduler wake times.

  HttpMethod* = enum ## HTTP methods accepted by Discord REST routes.
    hmDelete, ## DELETE request.
    hmGet, ## GET request.
    hmPatch, ## PATCH request.
    hmPost, ## POST request.
    hmPut ## PUT request.

  RequestPriority* = enum ## Scheduler lane; lower ordinals are more urgent.
    rpInteractionAck, ## Initial interaction acknowledgement.
    rpForeground, ## User-visible work awaiting completion.
    rpNormal, ## Ordinary application request.
    rpBackground ## Command sync, cache fill, or maintenance work.

  Idempotency* = enum ## Evidence that permits an automatic retry.
    idNever, ## Repeating the request may duplicate an effect.
    idSafe, ## The HTTP operation is inherently safe to repeat.
    idWithNonce, ## Discord can suppress duplicates through a nonce.
    idExplicit ## The caller explicitly permits repetition.

  DiscordAuthRequirement* = enum ## Credential contract chosen by an operation.
    darConfigured, ## Raw compatibility: use the transport credential, if any.
    darNone, ## Never send an Authorization header for this request.
    darBot, ## Require a bot-token transport.
    darOAuthBearer, ## Require an OAuth2 bearer-token transport.
    darBotOrOAuthBearer ## Accept either authenticated transport kind.

  RetryPolicy* = object ## Bounded exponential-backoff policy.
    maxAttempts*: int ## Total attempts, including the first request.
    baseDelayMs*: int64 ## Delay before the first retry.
    maxDelayMs*: int64 ## Upper bound for a single retry delay.
    retryTransportErrors*: bool ## Retry failed network operations when safe.
    retryServerErrors*: bool ## Retry HTTP 5xx responses when safe.

  RequestMeta* = object ## Execution policy carried by a REST request.
    deadline*: Option[MonoMillis] ## Latest permitted dispatch time.
    priority*: RequestPriority ## Queue lane within eligible requests.
    retryPolicy*: RetryPolicy ## Backoff and retry limits.
    idempotency*: Idempotency ## Evidence required before retrying.
    auditReason*: Option[string] ## Optional Discord audit-log reason.
    cancellationId*: Option[uint64] ## Application cancellation group.

  RouteKey* = object ## Stable scheduler identity for a Discord route.
    httpMethod*: HttpMethod ## Method that participates in the bucket key.
    templatePath*: string ## Route template with non-major snowflakes replaced
      ## by names.
    majorParameter*: string ## Channel, guild, or webhook identity that
      ## partitions a bucket.

  RestBodyKind* = enum ## Transport representation of a request body.
    rbEmpty, ## No request body.
    rbBytes, ## Caller-supplied replayable bytes.
    rbJson, ## Encoded JSON with an authoritative content type.
    rbMultipart ## Replayable multipart sources opened for each attempt.

  RestBody* = object ## Explicit request body retained by scheduled work.
    ## Static variants expose bytes through `bodyBytes`; multipart remains a
    ## streamed value and must be handled by a multipart-aware transport.
    case kind*: RestBodyKind
    of rbEmpty:
      discard
    of rbBytes:
      bytesValue*: seq[byte]
      bytesContentType*: string
    of rbJson:
      jsonValue*: seq[byte]
    of rbMultipart:
      multipartValue*: MultipartBody

  RawRequest* = object ## Fully rendered request accepted by the REST runtime.
    route*: RouteKey ## Token-free scheduler and diagnostic identity.
    urlPath*: string ## Rendered API path; may contain a webhook token.
    headers*: seq[(string, string)] ## Non-authoritative request headers.
    body*: RestBody ## Replayable body representation for every attempt.
    authRequirement*: DiscordAuthRequirement ## Operation-owned credential
      ## requirement. It never contains credential bytes.
    meta*: RequestMeta ## Scheduling, retry, and cancellation policy.

const
  MaxRetryAttempts* = 32 ## Maximum total attempts accepted by the scheduler.

func `<`*(a, b: MonoMillis): bool {.borrow.}
  ## Compares monotonic instants.
func `<=`*(a, b: MonoMillis): bool {.borrow.}
  ## Compares monotonic instants, including equality.
func `==`*(a, b: MonoMillis): bool {.borrow.}
  ## Tests two monotonic instants for equality.
func `+`*(a: MonoMillis, b: int64): MonoMillis {.borrow.}
  ## Adds a millisecond duration to an instant.
func `-`*(a, b: MonoMillis): int64 {.borrow.}
  ## Returns the signed millisecond distance between two instants.

func defaultRetryPolicy*(): RetryPolicy =
  ## Returns the conservative retry defaults for eligible requests.
  RetryPolicy(
    maxAttempts: 3,
    baseDelayMs: 250,
    maxDelayMs: 5_000,
    retryTransportErrors: true,
    retryServerErrors: true
  )

func validate*(policy: RetryPolicy): seq[string] =
  ## Returns retry-policy problems that would make scheduling unsafe.
  ##
  ## The attempt cap bounds retained work even when callers construct public
  ## request objects directly. Delay constraints keep backoff monotonic and
  ## prevent invalid values from turning retries into a hot loop.
  if policy.maxAttempts < 1:
    result.add "retry maxAttempts must be at least one"
  elif policy.maxAttempts > MaxRetryAttempts:
    result.add "retry maxAttempts exceeds the scheduler limit"
  if policy.baseDelayMs < 0:
    result.add "retry baseDelayMs must not be negative"
  if policy.maxDelayMs < 0:
    result.add "retry maxDelayMs must not be negative"
  if policy.baseDelayMs > policy.maxDelayMs:
    result.add "retry baseDelayMs must not exceed maxDelayMs"

func valid*(policy: RetryPolicy): bool =
  ## Reports whether a retry policy is safe for scheduler admission.
  policy.validate().len == 0

func defaultRequestMeta*(): RequestMeta =
  ## Returns normal-priority metadata with retries disabled by idempotency.
  RequestMeta(
    priority: rpNormal,
    retryPolicy: defaultRetryPolicy(),
    idempotency: idNever
  )

func emptyBody*(): RestBody =
  ## Creates a request without a body.
  RestBody(kind: rbEmpty)

proc bytesBody*(data: sink seq[byte],
                contentType = "application/octet-stream"): RestBody =
  ## Creates a replayable byte body with one safe media type.
  if not contentType.validContentType():
    raise newException(ValueError, "request content type is not header-safe")
  RestBody(
    kind: rbBytes,
    bytesValue: data,
    bytesContentType: contentType
  )

proc jsonBody*(document: JsonNode): RestBody =
  ## Serializes one JSON document into replayable request bytes.
  if document.isNil:
    raise newException(ValueError, "JSON request body must not be nil")
  let encoded = $document
  var data = newSeq[byte](encoded.len)
  for index, character in encoded:
    data[index] = byte(ord(character))
  RestBody(kind: rbJson, jsonValue: data)

func jsonBody*(encoded: sink seq[byte]): RestBody =
  ## Wraps already-encoded replayable JSON bytes.
  RestBody(kind: rbJson, jsonValue: encoded)

func multipartBody*(body: sink MultipartBody): RestBody =
  ## Wraps a source-backed multipart body for scheduled transport.
  RestBody(kind: rbMultipart, multipartValue: body)

converter toRestBody*(data: seq[byte]): RestBody =
  ## Transitional conversion for callers that constructed `RawRequest` with
  ## serialized bytes before `RestBody` became explicit.
  RestBody(
    kind: rbBytes,
    bytesValue: data,
    bytesContentType: "application/octet-stream"
  )

func bodyBytes*(body: RestBody): seq[byte] =
  ## Returns replayable static bytes, or raises for streamed multipart bodies.
  ##
  ## Raises `ValueError` for `rbMultipart` because materializing all upload
  ## sources would violate the streaming contract.
  case body.kind
  of rbEmpty:
    @[]
  of rbBytes:
    body.bytesValue
  of rbJson:
    body.jsonValue
  of rbMultipart:
    raise newException(ValueError,
      "streamed multipart bodies do not have an in-memory byte value")

func replayable*(body: RestBody): bool =
  ## Reports whether a later transport attempt can reproduce this body.
  case body.kind
  of rbEmpty, rbBytes, rbJson:
    true
  of rbMultipart:
    body.multipartValue.replayable()

func contentLength*(body: RestBody): Option[int64] =
  ## Returns an exact wire body length when it is knowable before streaming.
  case body.kind
  of rbEmpty:
    some(0'i64)
  of rbBytes:
    some(int64(body.bytesValue.len))
  of rbJson:
    some(int64(body.jsonValue.len))
  of rbMultipart:
    body.multipartValue.contentLength()

proc initRawRequest*(route: RouteKey, urlPath: string,
                     body = emptyBody(),
                     meta = defaultRequestMeta(),
                     headers: openArray[(string, string)] = []): RawRequest =
  ## Creates a transport request while retaining an explicit replayable body.
  let policyProblems = meta.retryPolicy.validate()
  if policyProblems.len != 0:
    raise newException(ValueError, policyProblems.join("; "))
  RawRequest(
    route: route,
    urlPath: urlPath,
    headers: @headers,
    body: body,
    authRequirement: darConfigured,
    meta: meta
  )

func routeKey*(httpMethod: HttpMethod, templatePath: string,
               majorParameter = ""): RouteKey =
  ## Creates a stable route key without rendered sensitive path values.
  RouteKey(
    httpMethod: httpMethod,
    templatePath: templatePath,
    majorParameter: majorParameter
  )

func `$`*(httpMethod: HttpMethod): string =
  ## Returns the uppercase wire spelling of an HTTP method.
  case httpMethod
  of hmDelete: "DELETE"
  of hmGet: "GET"
  of hmPatch: "PATCH"
  of hmPost: "POST"
  of hmPut: "PUT"

func canonical*(route: RouteKey): string =
  ## Returns the token-free route identity used for bucket discovery.
  result = $route.httpMethod & " " & route.templatePath
  if route.majorParameter.len != 0:
    result.add(" #" & route.majorParameter)

func `$`*(request: RawRequest): string =
  ## Omits rendered paths, headers, bodies, and caller-defined route templates.
  ## Raw escape hatches may place a credential in any of those fields.
  $request.route.httpMethod & " [REST request]"

func repr*(request: RawRequest): string =
  ## Uses the same credential-free representation as `$`.
  $request

proc `%`*(request: RawRequest): JsonNode =
  ## Serializes only the credential-free diagnostic representation.
  newJString($request)

proc toJsonHook*(request: RawRequest): JsonNode =
  ## Keeps `std/jsonutils` from traversing rendered request fields.
  %request

func canRetry*(meta: RequestMeta): bool =
  ## Reports whether the caller supplied sufficient idempotency evidence.
  meta.idempotency in {idSafe, idWithNonce, idExplicit}

func retryDelayMs*(policy: RetryPolicy, attempt: int): int64 =
  ## Computes capped exponential backoff for a one-based attempt number.
  ##
  ## Attempt two is the first retry and therefore uses `baseDelayMs`; attempt
  ## three doubles it once. Invalid negative inputs are clamped here so this
  ## helper remains total, while scheduler admission rejects such policies.
  let delayCap = max(0'i64, policy.maxDelayMs)
  var delay = min(max(0'i64, policy.baseDelayMs), delayCap)
  if delay == 0 or attempt <= 2:
    return delay
  var remaining = attempt - 2
  while remaining > 0 and delay < delayCap:
    if delay > delayCap div 2:
      return delayCap
    delay *= 2
    dec remaining
  min(delay, delayCap)

func validateAuditReason*(reason: string): bool =
  ## Checks CR/LF injection and Discord's 512-byte URL-encoded boundary.
  '\r' notin reason and '\n' notin reason and encodeUrl(reason).len <= 512

func redactHeader*(name, value: string): string =
  ## Replaces known credential-bearing header values with a fixed marker.
  if name.toLowerAscii() in ["authorization", "x-signature-ed25519"]:
    "<redacted>"
  else:
    value
