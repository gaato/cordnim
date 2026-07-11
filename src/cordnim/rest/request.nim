## Transport-neutral REST request metadata.
##
## The scheduler uses integer monotonic milliseconds so it can be tested with a
## fake clock. The Chronos adapter is the only layer that converts `Moment` to
## this representation.

import std/[options, strutils, uri]

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

  RawRequest* = object ## Fully rendered request accepted by the REST runtime.
    route*: RouteKey ## Token-free scheduler and diagnostic identity.
    urlPath*: string ## Rendered API path; may contain a webhook token.
    headers*: seq[(string, string)] ## Non-authoritative request headers.
    body*: seq[byte] ## Serialized request body.
    meta*: RequestMeta ## Scheduling, retry, and cancellation policy.

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

func defaultRequestMeta*(): RequestMeta =
  ## Returns normal-priority metadata with retries disabled by idempotency.
  RequestMeta(
    priority: rpNormal,
    retryPolicy: defaultRetryPolicy(),
    idempotency: idNever
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

func canRetry*(meta: RequestMeta): bool =
  ## Reports whether the caller supplied sufficient idempotency evidence.
  meta.idempotency in {idSafe, idWithNonce, idExplicit}

func retryDelayMs*(policy: RetryPolicy, attempt: int): int64 =
  ## Computes capped exponential backoff for a one-based attempt number.
  var delay = policy.baseDelayMs
  var remaining = max(1, attempt) - 1
  while remaining > 0 and delay < policy.maxDelayMs:
    if delay > policy.maxDelayMs div 2:
      return policy.maxDelayMs
    delay *= 2
    dec remaining
  min(delay, policy.maxDelayMs)

func validateAuditReason*(reason: string): bool =
  ## Checks CR/LF injection and Discord's 512-byte URL-encoded boundary.
  '\r' notin reason and '\n' notin reason and encodeUrl(reason).len <= 512

func redactHeader*(name, value: string): string =
  ## Replaces known credential-bearing header values with a fixed marker.
  if name.toLowerAscii() in ["authorization", "x-signature-ed25519"]:
    "<redacted>"
  else:
    value
