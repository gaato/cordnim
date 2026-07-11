## Concrete Discord HTTP transport implemented exclusively with Chronos.

import std/[math, options, strutils, uri]

import chronos
import chronos/apps/http/httpclient as chronosHttp

import cordnim/core/secrets
import ./[chronos_driver, request, scheduler]

const
  DiscordApiBaseUrl* = "https://discord.com/api/v10" ## Stable API v10 origin.
  CordnimUserAgent* = "DiscordBot (" &
    "https://github.com/gaato/cordnim, 0.1.0)" ## Default Discord user agent.
  MaxRateLimitDelaySeconds = 24.0 * 60.0 * 60.0
    # Longer values are not credible Discord bucket windows and would make a
    # scheduler sleep effectively forever even if integer conversion succeeded.

type
  ResponseBodyLimitError* = object of CatchableError ## Raised before retaining
    ## more than the configured response body limit.

  DiscordHttpTransport* = ref object ## Reusable Chronos HTTP session.
    session: HttpSessionRef
    token: Option[Secret[BotToken]]
    baseUrl: string
    maxResponseBodyBytes: int

func loopbackHost(hostname: string): bool =
  hostname.cmpIgnoreCase("localhost") == 0 or
    hostname == "127.0.0.1" or hostname == "::1"

proc checkedBaseUrl(value: string): string =
  let parsed = parseUri(value)
  if parsed.hostname.len == 0 or parsed.query.len != 0 or
      parsed.anchor.len != 0 or parsed.username.len != 0 or
      parsed.password.len != 0:
    raise newException(ValueError,
      "Discord API base URL must be an origin with an optional path")
  if parsed.scheme == "https":
    discard
  elif parsed.scheme == "http" and parsed.hostname.loopbackHost:
    discard
  else:
    raise newException(ValueError,
      "Discord API base URL must use HTTPS; HTTP is limited to loopback tests")
  value.strip(chars = {'/'})

func chronosMethod(httpMethod: request.HttpMethod): chronosHttp.HttpMethod =
  case httpMethod
  of hmDelete: MethodDelete
  of hmGet: MethodGet
  of hmPatch: MethodPatch
  of hmPost: MethodPost
  of hmPut: MethodPut

func headerValue(headers: openArray[(string, string)], name: string):
                 Option[string] =
  for (key, value) in headers:
    if key.cmpIgnoreCase(name) == 0:
      return some(value)
  none(string)

func parseIntHeader(headers: openArray[(string, string)],
                    name: string): Option[int] =
  let value = headers.headerValue(name)
  if value.isNone:
    return none(int)
  try:
    some(parseInt(value.get()))
  except ValueError:
    none(int)

func parseSecondsHeader(headers: openArray[(string, string)],
                        name: string): Option[int64] =
  let value = headers.headerValue(name)
  if value.isNone:
    return none(int64)
  try:
    let seconds = parseFloat(value.get())
    # Reject non-finite, negative, and out-of-range values before the narrowing
    # conversion. A hostile proxy header must not become a RangeDefect.
    if seconds.classify in {fcNan, fcInf, fcNegInf} or seconds < 0.0 or
        seconds > MaxRateLimitDelaySeconds:
      return none(int64)
    some(int64(seconds * 1_000.0))
  except ValueError:
    none(int64)

func parseRateLimitUpdate*(status: int,
                           headers: openArray[(string, string)]):
                           RateLimitUpdate =
  ## Parses Discord rate-limit headers without assuming fixed bucket values.
  result.bucketId = headers.headerValue("X-RateLimit-Bucket")
  result.limit = headers.parseIntHeader("X-RateLimit-Limit")
  result.remaining = headers.parseIntHeader("X-RateLimit-Remaining")
  result.resetAfterMs = headers.parseSecondsHeader("X-RateLimit-Reset-After")
  result.retryAfterMs = headers.parseSecondsHeader("Retry-After")
  result.wasRateLimited = status == 429
  let scope = headers.headerValue("X-RateLimit-Scope")
  let global = headers.headerValue("X-RateLimit-Global")
  if (global.isSome and global.get().toLowerAscii() == "true") or
      (scope.isSome and scope.get().toLowerAscii() == "global"):
    result.scope = rlsGlobal
  elif scope.isSome and scope.get().toLowerAscii() == "shared":
    result.scope = rlsShared
  else:
    result.scope = rlsUser

proc readBounded(response: HttpClientResponseRef,
                 limit: int): Future[seq[byte]] {.
                 async: (raises: [CancelledError, AsyncStreamError, HttpError,
                   ResponseBodyLimitError]).} =
  if limit <= 0:
    raise newException(ResponseBodyLimitError,
      "response body limit must be positive")
  if response.contentLength > uint64(limit):
    raise newException(ResponseBodyLimitError,
      "Discord response exceeds configured body limit")

  var reader = response.getBodyReader()
  var chunk: array[16 * 1_024, byte]
  try:
    while true:
      let count = await reader.readOnce(addr chunk[0], chunk.len)
      if count == 0:
        break
      if result.len > limit - count:
        raise newException(ResponseBodyLimitError,
          "Discord response exceeds configured body limit")
      result.add(chunk.toOpenArray(0, count - 1))
    await reader.closeWait()
    reader = nil
    await response.finish()
  finally:
    if not reader.isNil:
      await reader.closeWait()

proc execute(transport: DiscordHttpTransport,
             cordRequest: RawRequest): Future[TransportResponse] {.
             async: (raises: [CancelledError, AsyncStreamError, HttpError,
               ValueError, ResponseBodyLimitError]).} =
  if cordRequest.urlPath.len == 0 or cordRequest.urlPath[0] != '/' or
      "://" in cordRequest.urlPath:
    raise newException(ValueError, "REST path must be an absolute API path")

  var headers: seq[(string, string)]
  for (name, value) in cordRequest.headers:
    if name.toLowerAscii() notin [
        "authorization", "user-agent", "x-audit-log-reason"]:
      headers.add((name, value))
  # Authentication and audit metadata have one authoritative source. Accepting
  # caller-provided duplicates would make redaction and signature review
  # brittle.
  if transport.token.isSome:
    headers.add(("Authorization", "Bot " & transport.token.get().reveal()))
  headers.add(("User-Agent", CordnimUserAgent))
  if cordRequest.meta.auditReason.isSome:
    let reason = cordRequest.meta.auditReason.get()
    if not reason.validateAuditReason:
      raise newException(ValueError, "invalid Discord audit log reason")
    headers.add(("X-Audit-Log-Reason", encodeUrl(reason)))

  let built = HttpClientRequestRef.new(
    transport.session,
    transport.baseUrl & cordRequest.urlPath,
    cordRequest.route.httpMethod.chronosMethod,
    headers = headers,
    body = cordRequest.body
  )
  if built.isErr:
    # Chronos diagnostics may echo the complete URL, including a webhook or
    # interaction token embedded in its path. Keep that value behind the
    # transport redaction boundary.
    raise newException(ValueError, "invalid Discord REST URL")
  let httpRequest = built.get()
  var response: HttpClientResponseRef
  try:
    response = await httpRequest.send()
    var responseHeaders: seq[(string, string)]
    for item in response.headers.toList():
      responseHeaders.add((item.key, item.value))
    let body = await response.readBounded(transport.maxResponseBodyBytes)
    result = TransportResponse(
      status: response.status,
      headers: responseHeaders,
      body: body,
      rateLimit: parseRateLimitUpdate(response.status, responseHeaders)
    )
  finally:
    if not response.isNil:
      await response.closeWait()
    if not httpRequest.isNil:
      await httpRequest.closeWait()

proc newDiscordHttpTransport*(token: Secret[BotToken],
                              baseUrl = DiscordApiBaseUrl,
                              maxResponseBodyBytes = 16 * 1_024 * 1_024):
                              DiscordHttpTransport =
  ## Creates a TLS-verifying, connection-reusing Discord transport.
  if token.isEmpty:
    raise newException(ValueError, "Discord bot token must not be empty")
  if maxResponseBodyBytes <= 0:
    raise newException(ValueError, "response body limit must be positive")
  let checkedUrl = baseUrl.checkedBaseUrl()
  DiscordHttpTransport(
    session: HttpSessionRef.new({HttpClientFlag.Http11Pipeline}),
    token: some(token),
    baseUrl: checkedUrl,
    maxResponseBodyBytes: maxResponseBodyBytes
  )

proc newWebhookHttpTransport*(baseUrl = DiscordApiBaseUrl,
                              maxResponseBodyBytes = 16 * 1_024 * 1_024):
                              DiscordHttpTransport =
  ## Creates a transport for token-in-path interaction/webhook endpoints.
  ##
  ## No Authorization header is added. The same TLS verification and response
  ## limits as the bot transport remain active.
  if maxResponseBodyBytes <= 0:
    raise newException(ValueError, "response body limit must be positive")
  let checkedUrl = baseUrl.checkedBaseUrl()
  DiscordHttpTransport(
    session: HttpSessionRef.new({HttpClientFlag.Http11Pipeline}),
    token: none(Secret[BotToken]),
    baseUrl: checkedUrl,
    maxResponseBodyBytes: maxResponseBodyBytes
  )

proc asRestTransport*(transport: DiscordHttpTransport): RestTransport =
  ## Erases the concrete session behind the scheduler transport callback.
  result = proc(request: RawRequest): Future[TransportResponse]
      {.gcsafe, raises: [].} =
    transport.execute(request)

proc close*(transport: DiscordHttpTransport): Future[void] {.
            async: (raises: []).} =
  ## Closes all pooled HTTP connections.
  if not transport.isNil and not transport.session.isNil:
    await transport.session.closeWait()
