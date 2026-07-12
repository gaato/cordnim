## Concrete Discord HTTP transport implemented exclusively with Chronos.
##
## Chronos 4.2 collapses an initial TLS protocol/handshake failure into the same
## `HttpConnectionError` used for transient connection failures. Cordnim cannot
## distinguish those cases without patching the dependency, so an idempotent
## request may consume its bounded transport retry budget for that one class.

import std/[json, math, options, strutils, uri]

import chronos
import chronos/apps/http/httpclient as chronosHttp
import chronos/apps/http/multipart as chronosMultipart
import chronos/streams/boundstream as chronosBound
import chronos/streams/chunkstream as chronosChunk
import chronos/streams/tlsstream as chronosTls

import cordnim/build_info
import cordnim/core/errors as cordErrors
import cordnim/core/secrets
import ./[chronos_driver, request, scheduler]
import ./multipart as cordMultipart

const
  DiscordApiBaseUrl* = "https://discord.com/api/v10" ## Stable API v10 origin.
  CordnimUserAgent* = CordnimDiscordUserAgent ## Default Discord user agent.
  MaxRateLimitDelaySeconds = 24.0 * 60.0 * 60.0
    # Longer values are not credible Discord bucket windows and would make a
    # scheduler sleep effectively forever even if integer conversion succeeded.
  MaxRateLimitFallbackBodyBytes = 64 * 1_024
    # A 429 document is tiny. Do not parse an arbitrarily large hostile body
    # merely to recover optional rate-limit metadata.

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
  if parsed.port.len != 0:
    try:
      let port = parseInt(parsed.port)
      if port <= 0 or port > 65_535:
        raise newException(ValueError,
          "Discord API base URL port is out of range")
    except ValueError:
      raise newException(ValueError,
        "Discord API base URL port is invalid")
  value.strip(chars = {'/'})

func chronosMethod(httpMethod: request.HttpMethod): chronosHttp.HttpMethod =
  case httpMethod
  of hmDelete: MethodDelete
  of hmGet: MethodGet
  of hmPatch: MethodPatch
  of hmPost: MethodPost
  of hmPut: MethodPut

func validHeaderName(value: string): bool =
  if value.len == 0:
    return false
  for character in value:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '!', '#', '$', '%',
        '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'}:
      return false
  true

func validHeaderValue(value: string): bool =
  for character in value:
    let ordinal = ord(character)
    if character == '\\' or ordinal == 0 or ordinal == 0x7f or
        (ordinal < 0x20 and character != '\t'):
      return false
  true

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
    some(int64(ceil(seconds * 1_000.0)))
  except ValueError:
    none(int64)

func parseJsonDelay(node: JsonNode): Option[int64] =
  if node.isNil:
    return none(int64)
  case node.kind
  of JInt:
    let seconds = node.getBiggestInt()
    if seconds < 0 or seconds > BiggestInt(MaxRateLimitDelaySeconds):
      return none(int64)
    some(int64(seconds) * 1_000'i64)
  of JFloat:
    let seconds = node.getFloat()
    if seconds.classify in {fcNan, fcInf, fcNegInf} or seconds < 0.0 or
        seconds > MaxRateLimitDelaySeconds:
      return none(int64)
    some(int64(ceil(seconds * 1_000.0)))
  else:
    none(int64)

proc parseRateLimitBody(body: openArray[byte]): JsonNode =
  if body.len == 0 or body.len > MaxRateLimitFallbackBodyBytes:
    return nil
  var text = newString(body.len)
  for index, value in body:
    text[index] = char(value)
  try:
    result = parseJson(text)
    if result.kind != JObject:
      result = nil
  except CatchableError:
    result = nil

proc parseRateLimitUpdate*(status: int,
                           headers: openArray[(string, string)],
                           body: openArray[byte] = []): RateLimitUpdate =
  ## Parses Discord rate-limit headers with a bounded HTTP 429 body fallback.
  result.bucketId = headers.headerValue("X-RateLimit-Bucket")
  result.limit = headers.parseIntHeader("X-RateLimit-Limit")
  result.remaining = headers.parseIntHeader("X-RateLimit-Remaining")
  result.resetAfterMs = headers.parseSecondsHeader("X-RateLimit-Reset-After")
  result.wasRateLimited = status == 429

  let retryAfterHeader = headers.headerValue("Retry-After")
  let scope = headers.headerValue("X-RateLimit-Scope")
  let global = headers.headerValue("X-RateLimit-Global")
  if retryAfterHeader.isSome:
    result.retryAfterMs = headers.parseSecondsHeader("Retry-After")

  var fallback: JsonNode
  if status == 429 and
      (retryAfterHeader.isNone or (scope.isNone and global.isNone)):
    fallback = body.parseRateLimitBody()
  if retryAfterHeader.isNone and not fallback.isNil and
      fallback.hasKey("retry_after"):
    result.retryAfterMs = fallback["retry_after"].parseJsonDelay()

  if (global.isSome and global.get().toLowerAscii() == "true") or
      (scope.isSome and scope.get().toLowerAscii() == "global"):
    result.scope = rlsGlobal
  elif scope.isSome and scope.get().toLowerAscii() == "shared":
    result.scope = rlsShared
  elif scope.isNone and global.isNone and not fallback.isNil and
      fallback.hasKey("global") and fallback["global"].kind == JBool and
      fallback["global"].getBool():
    result.scope = rlsGlobal
  else:
    result.scope = rlsUser

proc readBounded(response: HttpClientResponseRef,
                 limit: int): Future[seq[byte]] {.
                 async: (raises: [CancelledError, AsyncStreamError,
                   chronosHttp.HttpError, ResponseBodyLimitError]).} =
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

proc multipartHeaders(contentType: string): chronosMultipart.HttpTable =
  result = chronosMultipart.HttpTable.init()
  result.add("Content-Type", contentType)

proc openUploadSource(source: cordMultipart.UploadSource):
                      Future[cordMultipart.UploadCursor] {.async.} =
  # Source callbacks are application code, not Chronos writer operations.
  # Only the explicit cordnim transport category opts a custom source into
  # retry; every other source failure is terminal and redacted.
  try:
    return await cordMultipart.openCursor(source)
  except CancelledError:
    raise
  except cordErrors.TransportError:
    raise
  except CatchableError:
    raise newException(ValueError, "multipart upload source failed")

proc readUploadSource(cursor: cordMultipart.UploadCursor): Future[seq[byte]] {.
                      async.} =
  try:
    return await cordMultipart.readChunk(cursor)
  except CancelledError:
    raise
  except cordErrors.TransportError:
    raise
  except CatchableError:
    raise newException(ValueError, "multipart upload source failed")

proc closeUploadSource(cursor: cordMultipart.UploadCursor): Future[void] {.
                       async.} =
  try:
    await cordMultipart.close(cursor)
  except CancelledError:
    raise
  except cordErrors.TransportError:
    raise
  except CatchableError:
    raise newException(ValueError, "multipart upload source cleanup failed")

proc writeMultipartRequest(request: HttpClientRequestRef,
                           body: cordMultipart.MultipartBody):
                           Future[HttpClientResponseRef] {.async.} =
  let problems = body.validate()
  if problems.len != 0:
    raise newException(ValueError, problems.join("; "))

  var writer: chronosMultipart.HttpBodyWriter
  try:
    writer = await request.open()
    let multipartWriter = chronosMultipart.MultiPartWriterRef.new(
      writer, body.boundary)
    await multipartWriter.begin()

    await multipartWriter.beginPart(
      "payload_json", "", multipartHeaders("application/json"))
    if body.payloadJson.len != 0:
      await multipartWriter.write(body.payloadJson)
    await multipartWriter.finishPart()

    var uploadIndex = 0
    for edit in body.uploads():
      var cursor: cordMultipart.UploadCursor
      var primaryError: ref CatchableError
      try:
        cursor = await openUploadSource(edit.source)
        await multipartWriter.beginPart(
          "files[" & $uploadIndex & "]",
          edit.filename,
          multipartHeaders(edit.contentType)
        )
        while true:
          let chunk = await readUploadSource(cursor)
          if chunk.len == 0:
            break
          await multipartWriter.write(chunk)
        await multipartWriter.finishPart()
      except CatchableError as error:
        primaryError = error
      finally:
        if not cursor.isNil:
          try:
            await noCancel(closeUploadSource(cursor))
          except CatchableError:
            # Cleanup must not replace the writer/source/cancellation failure
            # that caused cleanup to run. A standalone close failure remains
            # observable and is classified by its source-boundary helper.
            if primaryError.isNil:
              raise
      if not primaryError.isNil:
        raise primaryError
      inc uploadIndex

    await multipartWriter.finish()
    await writer.finish()
    await noCancel(writer.closeWait())
    return await request.finish()
  finally:
    if not writer.isNil and not writer.closed():
      await noCancel(writer.closeWait())

proc addBodyHeaders(body: RestBody,
                    headers: var seq[(string, string)]) =
  case body.kind
  of rbEmpty:
    discard
  of rbBytes:
    if not cordMultipart.validContentType(body.bytesContentType):
      raise newException(ValueError, "request content type is not header-safe")
    headers.add(("Content-Type", body.bytesContentType))
    headers.add(("Content-Length", $body.bytesValue.len))
  of rbJson:
    headers.add(("Content-Type", "application/json"))
    headers.add(("Content-Length", $body.jsonValue.len))
  of rbMultipart:
    let problems = body.multipartValue.validate()
    if problems.len != 0:
      raise newException(ValueError, problems.join("; "))
    headers.add(("Content-Type", "multipart/form-data; boundary=" &
      body.multipartValue.boundary))
    let length = body.multipartValue.contentLength()
    if length.isSome:
      headers.add(("Content-Length", $length.get()))
    else:
      headers.add(("Transfer-Encoding", "chunked"))

proc execute(transport: DiscordHttpTransport,
             cordRequest: RawRequest): Future[TransportResponse] {.
             async: (raises: [CancelledError, AsyncStreamError,
               chronosHttp.HttpError, cordErrors.TransportError, ValueError,
               ResponseBodyLimitError]).} =
  if cordRequest.urlPath.len == 0 or cordRequest.urlPath[0] != '/' or
      "://" in cordRequest.urlPath:
    raise newException(ValueError, "REST path must be an absolute API path")

  var headers: seq[(string, string)]
  for (name, value) in cordRequest.headers:
    if not name.validHeaderName() or not value.validHeaderValue():
      raise newException(ValueError, "REST request header is not safe")
    if name.toLowerAscii() notin [
        "authorization", "content-length", "content-type",
        "transfer-encoding", "user-agent", "x-audit-log-reason"]:
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

  cordRequest.body.addBodyHeaders(headers)

  let staticBody =
    case cordRequest.body.kind
    of rbEmpty, rbMultipart:
      @[]
    of rbBytes:
      cordRequest.body.bytesValue
    of rbJson:
      cordRequest.body.jsonValue

  let address = transport.session.getHttpAddress(
    parseUri(transport.baseUrl & cordRequest.urlPath))
  if address.isErr:
    if address.error().isRecoverableError():
      raise cordErrors.newDiscordError(
        cordErrors.TransportError, "Discord REST address resolution failed")
    raise newException(ValueError, "invalid Discord REST URL")
  let httpRequest = HttpClientRequestRef.new(
    transport.session,
    address.get(),
    cordRequest.route.httpMethod.chronosMethod,
    headers = headers,
    body = staticBody
  )
  var response: HttpClientResponseRef
  try:
    if cordRequest.body.kind == rbMultipart:
      try:
        response = await httpRequest.writeMultipartRequest(
          cordRequest.body.multipartValue)
      except CancelledError:
        raise
      except cordErrors.TransportError:
        # A custom async source can explicitly classify its own transient I/O
        # failure without exposing its error text beyond this boundary.
        raise
      except chronosBound.BoundedStreamIncompleteError,
          chronosBound.BoundedStreamOverflowError:
        raise newException(ValueError,
          "multipart framing did not match its declared length")
      except AsyncStreamError:
        # Multipart framing writes use Chronos streams. Keep their I/O
        # category intact until `executeClassified` applies the public
        # redaction boundary.
        raise
      except chronosHttp.HttpTransportError:
        raise
      except CatchableError:
        # A custom source may expose a path or credential in its error text.
        # Preserve only a stable category across the transport boundary.
        raise newException(ValueError, "multipart upload failed")
    else:
      response = await httpRequest.send()
    var responseHeaders: seq[(string, string)]
    for item in response.headers.toList():
      responseHeaders.add((item.key, item.value))
    let body = await response.readBounded(transport.maxResponseBodyBytes)
    result = TransportResponse(
      status: response.status,
      headers: responseHeaders,
      body: body,
      rateLimit: parseRateLimitUpdate(response.status, responseHeaders, body)
    )
  finally:
    if not response.isNil:
      await response.closeWait()
    if not httpRequest.isNil:
      await httpRequest.closeWait()

proc executeClassified(transport: DiscordHttpTransport,
                       request: RawRequest): Future[TransportResponse] {.
                       async: (raises: [CancelledError,
                         cordErrors.DiscordError]).} =
  ## Translates only transient Chronos I/O failures into the retryable category.
  try:
    return await transport.execute(request)
  except CancelledError:
    raise
  except ValueError:
    raise cordErrors.newDiscordError(
      cordErrors.ValidationError, "Discord REST request validation failed")
  except ResponseBodyLimitError:
    raise cordErrors.newDiscordError(
      cordErrors.DecodeError, "Discord REST response body limit exceeded")
  except cordErrors.TransportError:
    raise
  except chronosChunk.ChunkedStreamProtocolError:
    raise cordErrors.newDiscordError(
      cordErrors.DecodeError, "Discord REST response framing was invalid")
  except chronosChunk.AsyncStreamLimitError:
    raise cordErrors.newDiscordError(
      cordErrors.DecodeError, "Discord REST response stream limit was exceeded")
  except chronosChunk.AsyncStreamUseClosedError:
    raise cordErrors.newDiscordError(
      cordErrors.ValidationError, "Discord REST stream state was invalid")
  except chronosBound.BoundedStreamOverflowError:
    raise cordErrors.newDiscordError(
      cordErrors.DecodeError, "Discord REST response exceeded its framing")
  except chronosTls.TLSStreamProtocolError:
    raise cordErrors.newDiscordError(
      cordErrors.DecodeError, "Discord REST TLS protocol failed")
  except AsyncStreamError:
    # Chronos errors may include a credential-bearing URL. Preserve only the
    # category needed by retry policy at this subsystem boundary.
    raise cordErrors.newDiscordError(
      cordErrors.TransportError, "Discord REST network transport failed")
  except chronosHttp.HttpReadLimitError:
    raise cordErrors.newDiscordError(
      cordErrors.DecodeError, "Discord REST response headers exceeded limits")
  except chronosHttp.HttpTransportError:
    # Chronos errors may include a credential-bearing URL. Preserve only the
    # category needed by retry policy at this subsystem boundary.
    raise cordErrors.newDiscordError(
      cordErrors.TransportError, "Discord REST network transport failed")
  except chronosHttp.HttpInvalidUsageError:
    raise cordErrors.newDiscordError(
      cordErrors.ValidationError, "Discord REST HTTP state was invalid")
  except chronosHttp.HttpError:
    # Protocol and request-state failures are deterministic for the attempted
    # request. They remain terminal instead of consuming the retry budget.
    raise cordErrors.newDiscordError(
      cordErrors.DecodeError, "Discord REST HTTP protocol failed")

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
    transport.executeClassified(request)

proc close*(transport: DiscordHttpTransport): Future[void] {.
            async: (raises: []).} =
  ## Closes all pooled HTTP connections.
  if not transport.isNil and not transport.session.isNil:
    await transport.session.closeWait()
