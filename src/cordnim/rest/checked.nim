## Checked REST responses and optional `Result` conversion.
##
## The central scheduler returns every HTTP response so raw callers retain full
## control. This module adds the high-level contract: non-2xx responses become
## structured `DiscordError` subclasses without copying request or response
## bodies into diagnostics.

import std/[json, options, strutils, times]

import chronos
import results

import cordnim/core/errors
import ./[chronos_driver, request]

export results

type
  RestAttempt*[T] = Result[T, ref DiscordError]
    ## Explicit non-raising view of a checked asynchronous REST operation.

func responseHeader(headers: openArray[(string, string)],
                    name: string): Option[string] =
  for (key, value) in headers:
    if key.cmpIgnoreCase(name) == 0:
      return some(value)
  none(string)

func responseText(body: openArray[byte]): string =
  result = newString(body.len)
  for index, value in body:
    result[index] = char(value)

proc failureMeta(response: TransportResponse,
                 sanitizedRoute: string): DiscordFailureMeta =
  result.status = some(response.status)
  result.route = some(sanitizedRoute)
  result.bucket = response.headers.responseHeader("X-RateLimit-Bucket")
  result.requestId = response.headers.responseHeader("X-Request-ID")
  if response.rateLimit.retryAfterMs.isSome:
    result.retryAfter = some(initDuration(
      milliseconds = response.rateLimit.retryAfterMs.get()))
  if response.body.len != 0:
    try:
      let document = parseJson(response.body.responseText())
      if document.kind == JObject and document.hasKey("code") and
          document["code"].kind == JInt:
        result.discordCode = some(document["code"].getBiggestInt().int64)
    except CatchableError:
      # Discord error metadata is best-effort. A malformed error document must
      # not replace the original HTTP status with a JSON decoding failure.
      discard

proc submitChecked*(client: ChronosRestClient,
                    cordRequest: sink RawRequest): Future[TransportResponse] {.
                    async.} =
  ## Returns a successful response or raises a structured Discord error.
  let sanitizedRoute = cordRequest.route.canonical()
  let response = await client.submit(cordRequest)
  if response.status >= 200 and response.status < 300:
    return response

  let metadata = response.failureMeta(sanitizedRoute)
  if response.status == 429:
    raise newDiscordError(RateLimitError,
      "Discord REST rate limit could not be satisfied", metadata)
  if response.status == 403:
    raise newDiscordError(PermissionError,
      "Discord rejected the request permissions", metadata)
  raise newDiscordError(HttpError,
    "Discord REST request returned HTTP " & $response.status, metadata)

proc attemptFuture*[T](operation: Future[T]): Future[RestAttempt[T]] {.
                       async.} =
  ## Awaits a checked operation and captures only `DiscordError` failures.
  try:
    return RestAttempt[T].ok(await operation)
  except DiscordError as error:
    return RestAttempt[T].err(error)

template attempt*(client: ChronosRestClient, body: untyped): untyped =
  ## Converts `body` to `Future[Result[T, ref DiscordError]]` without nesting.
  ##
  ## Use `await attempt(client, client.submitChecked(request))`; all scheduling
  ## and I/O remain in the ordinary awaited expression.
  attemptFuture(body)
