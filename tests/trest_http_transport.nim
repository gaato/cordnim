import std/[json, options, strutils, unittest]

import chronos
import chronos/apps/http/httpserver
import httputils

import cordnim/core/errors as cordErrors
import cordnim/core/secrets
import cordnim/rest

type
  CaptureState = ref object
    bodies: seq[seq[byte]]
    contentTypes: seq[string]
    contentLengths: seq[string]
    transferEncodings: seq[string]
    authorizations: seq[string]
    responseCodes: seq[HttpCode]
    responseHeaders: seq[(string, string)]
    responseBody: seq[byte]
    bodyErrors: int

  SourceState = ref object
    data: seq[byte]
    declaredSize: Option[int64]
    replayable: bool
    blocked: bool
    readStarted: Future[void]
    blockedRead: Future[seq[byte]]
    retryableReadFailures: int
    terminalStreamReadFailures: int
    terminalStreamCloseFailures: int
    opens: int
    reads: int
    closes: int
    maxRequested: int

  RawPeerState = ref object
    connections: int

func bytes(value: string): seq[byte] =
  result = newSeq[byte](value.len)
  for index, character in value:
    result[index] = byte(ord(character))

func text(value: openArray[byte]): string =
  result = newString(value.len)
  for index, item in value:
    result[index] = char(item)

proc readyFuture[T](value: sink T): Future[T] =
  result = newFuture[T]("test.rest.http.completed")
  result.complete(value)

proc readyVoid(): Future[void] =
  result = newFuture[void]("test.rest.http.completed-void")
  result.complete()

proc trackedSource(state: SourceState): UploadSource =
  let open: UploadOpenProc = proc(): Future[UploadCursor]
      {.gcsafe, raises: [].} =
    inc state.opens
    var offset = 0
    let read: UploadReadProc = proc(maxBytes: int): Future[seq[byte]]
        {.gcsafe, raises: [].} =
      inc state.reads
      state.maxRequested = max(state.maxRequested, maxBytes)
      if state.retryableReadFailures > 0:
        dec state.retryableReadFailures
        let failed = newFuture[seq[byte]]("test.rest.http.retryable-read")
        failed.fail(cordErrors.newDiscordError(
          cordErrors.TransportError, "temporary upload source failure"))
        return failed
      if state.terminalStreamReadFailures > 0:
        dec state.terminalStreamReadFailures
        let failed = newFuture[seq[byte]]("test.rest.http.terminal-read")
        failed.fail(newException(
          AsyncStreamUseClosedError, "deterministic source stream failure"))
        return failed
      if state.blocked:
        if not state.readStarted.finished:
          state.readStarted.complete()
        return state.blockedRead

      let count = min(maxBytes, state.data.len - offset)
      var chunk = newSeq[byte](count)
      for index in 0..<count:
        chunk[index] = state.data[offset + index]
      offset += count
      readyFuture(chunk)
    let close: UploadCloseProc = proc(): Future[void]
        {.gcsafe, raises: [].} =
      inc state.closes
      if state.terminalStreamCloseFailures > 0:
        dec state.terminalStreamCloseFailures
        let failed = newFuture[void]("test.rest.http.terminal-close")
        failed.fail(newException(
          AsyncStreamUseClosedError, "deterministic source close failure"))
        return failed
      readyVoid()
    let opened = newFuture[UploadCursor]("test.rest.http.open")
    try:
      opened.complete(newUploadCursor(read, close))
    except CatchableError as error:
      opened.fail(error)
    opened
  initUploadSource(
    open, replayable = state.replayable, size = state.declaredSize)

proc startCaptureServer(state: CaptureState): HttpServerRef =
  proc callback(fence: RequestFence): Future[HttpResponseRef] {.
      async: (raises: [CancelledError]).} =
    if fence.isErr:
      return defaultResponse()
    let request = fence.get()
    state.contentTypes.add request.headers.getString("Content-Type")
    state.contentLengths.add request.headers.getString("Content-Length")
    state.transferEncodings.add request.headers.getString("Transfer-Encoding")
    state.authorizations.add request.headers.getString("Authorization")
    let body =
      try:
        await request.getBody()
      except CancelledError:
        raise
      except HttpTransportError:
        inc state.bodyErrors
        return defaultResponse()
      except HttpProtocolError:
        inc state.bodyErrors
        return defaultResponse()
    let index = state.bodies.len
    state.bodies.add body
    let responseCode =
      if index < state.responseCodes.len:
        state.responseCodes[index]
      else:
        Http200
    var responseHeaders = HttpTable.init()
    for (name, value) in state.responseHeaders:
      responseHeaders.add(name, value)
    try:
      return await request.respond(
        responseCode, state.responseBody, responseHeaders)
    except HttpWriteError:
      return defaultResponse()

  let built = HttpServerRef.new(
    initTAddress("127.0.0.1:0"),
    callback,
    serverIdent = "cordnim-test",
    maxRequestBodySize = 2 * 1_024 * 1_024
  )
  doAssert built.isOk
  result = built.get()
  result.start()

proc malformedChunkPeer(server: StreamServer, client: StreamTransport) {.
    async: (raises: []).} =
  let state = cast[RawPeerState](server.udata)
  inc state.connections
  try:
    while true:
      let line = await client.readLine()
      if line.len == 0:
        break
    discard await client.write(
      "HTTP/1.1 200 OK\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "Connection: close\r\n\r\n" &
      "not-a-hex-size\r\nbody\r\n0\r\n\r\n")
  except CatchableError:
    discard
  client.close()
  await noCancel(client.join())

proc noContentPeer(server: StreamServer, client: StreamTransport) {.
    async: (raises: []).} =
  let state = cast[RawPeerState](server.udata)
  inc state.connections
  try:
    while true:
      let line = await client.readLine()
      if line.len == 0:
        break
    discard await client.write(
      "HTTP/1.1 204 No Content\r\n" &
      "Connection: keep-alive\r\n\r\n")
    # Keep the peer open exactly as Discord does. The client must know from the
    # status that no body follows instead of waiting for EOF.
    await client.join()
  except CatchableError:
    discard
  if not client.closed:
    client.close()
    await noCancel(client.join())

func testMeta(maxAttempts = 1,
              cancellationId = none(uint64)): RequestMeta =
  result = defaultRequestMeta()
  result.idempotency = idExplicit
  result.cancellationId = cancellationId
  result.retryPolicy = RetryPolicy(
    maxAttempts: maxAttempts,
    baseDelayMs: 0,
    maxDelayMs: 0,
    retryTransportErrors: true,
    retryServerErrors: true
  )

proc uploadRequest(body: sink MultipartBody, maxAttempts = 1,
                   cancellationId = none(uint64)): RawRequest =
  initRawRequest(
    routeKey(hmPost, "/upload"),
    "/upload",
    body = multipartBody(body),
    meta = testMeta(maxAttempts, cancellationId)
  )

func baseUrl(server: HttpServerRef): string =
  "http://" & $server.instance.localAddress()

type
  WireOutcome = ref object
    capture: CaptureState
    source: SourceState
    status: int

  FailureOutcome = object
    failed: bool
    opens: int
    closes: int

  HttpFailureOutcome = object
    failed: bool
    requests: int

  AuthOutcome = object
    authorizations: seq[string]
    mismatchRejected: bool
    callerHeaderRejected: bool
    diagnosticsSafe: bool

  CredentialInjectionOutcome = object
    botRejected: bool
    bearerRejected: bool
    requests: int

  AuthDomainOutcome = object
    statuses: seq[int]
    blocked: bool
    requests: int
    authorizations: seq[string]

proc runRetryScenario(): Future[WireOutcome] {.async.} =
  var payload = newSeq[byte](2 * DefaultUploadChunkBytes + 17)
  for index in 0..<payload.len:
    payload[index] = byte(index mod 251)
  let sourceState = SourceState(
    data: payload,
    declaredSize: some(int64(payload.len)),
    replayable: true
  )
  let capture = CaptureState(responseCodes: @[Http500, Http200])
  let server = startCaptureServer(capture)
  let transport = newWebhookHttpTransport(server.baseUrl())
  let client = newChronosRestClient(transport.asRestTransport())
  client.start()
  try:
    var plan: AttachmentPlan
    plan.add uploadAttachment(
      "blob.bin", trackedSource(sourceState),
      contentType = "application/octet-stream",
      spoiler = setValue(true)
    )
    let body = initMultipartBody(
      %*{"content": "retry"}, plan, boundary = "cordnim-retry")
    let response = await client.submit(uploadRequest(body, maxAttempts = 2))
    return WireOutcome(
      capture: capture, source: sourceState, status: response.status)
  finally:
    await client.stop()
    await transport.close()
    await server.closeWait()

proc runUnknownSizeScenario(): Future[WireOutcome] {.async.} =
  let sourceState = SourceState(
    data: bytes("streamed-without-a-size"),
    declaredSize: none(int64),
    replayable: true
  )
  let capture = CaptureState(responseCodes: @[Http200])
  let server = startCaptureServer(capture)
  let transport = newWebhookHttpTransport(server.baseUrl())
  let client = newChronosRestClient(transport.asRestTransport())
  client.start()
  try:
    var plan: AttachmentPlan
    plan.add uploadAttachment("unknown.bin", trackedSource(sourceState))
    let body = initMultipartBody(
      %*{}, plan, boundary = "cordnim-chunked")
    let response = await client.submit(uploadRequest(body))
    return WireOutcome(
      capture: capture, source: sourceState, status: response.status)
  finally:
    await client.stop()
    await transport.close()
    await server.closeWait()

proc runZeroByteScenario(): Future[WireOutcome] {.async.} =
  let sourceState = SourceState(
    data: newSeq[byte](),
    declaredSize: some(0'i64),
    replayable: true
  )
  let capture = CaptureState(responseCodes: @[Http200])
  let server = startCaptureServer(capture)
  let transport = newWebhookHttpTransport(server.baseUrl())
  let client = newChronosRestClient(transport.asRestTransport())
  client.start()
  try:
    var plan: AttachmentPlan
    plan.add uploadAttachment("empty.bin", trackedSource(sourceState))
    let body = initMultipartBody(
      %*{"content": "empty"}, plan, boundary = "cordnim-empty")
    let response = await client.submit(uploadRequest(body))
    return WireOutcome(
      capture: capture, source: sourceState, status: response.status)
  finally:
    await client.stop()
    await transport.close()
    await server.closeWait()

proc runShortSourceScenario(): Future[FailureOutcome] {.async.} =
  let sourceState = SourceState(
    data: bytes("abc"),
    declaredSize: some(5'i64),
    replayable: true
  )
  let capture = CaptureState(responseCodes: @[Http200])
  let server = startCaptureServer(capture)
  let transport = newWebhookHttpTransport(server.baseUrl())
  let client = newChronosRestClient(transport.asRestTransport())
  client.start()
  try:
    var plan: AttachmentPlan
    plan.add uploadAttachment("short.bin", trackedSource(sourceState))
    let body = initMultipartBody(
      %*{}, plan, boundary = "cordnim-short")
    let pending = client.submit(uploadRequest(body, maxAttempts = 3))
    doAssert await pending.withTimeout(chronos.seconds(2))
    var failed = false
    try:
      discard await pending
    except CatchableError:
      failed = true
    return FailureOutcome(
      failed: failed, opens: sourceState.opens, closes: sourceState.closes)
  finally:
    await client.stop()
    await transport.close()
    await server.closeWait()

proc runRetryableSourceScenario(): Future[WireOutcome] {.async.} =
  let sourceState = SourceState(
    data: bytes("eventual upload"),
    declaredSize: some(15'i64),
    replayable: true,
    retryableReadFailures: 1
  )
  let capture = CaptureState(responseCodes: @[Http200])
  let server = startCaptureServer(capture)
  let transport = newWebhookHttpTransport(server.baseUrl())
  let client = newChronosRestClient(transport.asRestTransport())
  client.start()
  try:
    var plan: AttachmentPlan
    plan.add uploadAttachment("eventual.bin", trackedSource(sourceState))
    let body = initMultipartBody(
      %*{}, plan, boundary = "cordnim-source-retry")
    let response = await client.submit(uploadRequest(body, maxAttempts = 2))
    return WireOutcome(
      capture: capture, source: sourceState, status: response.status)
  finally:
    await client.stop()
    await transport.close()
    await server.closeWait()

proc runTerminalSourceScenario(failClose: bool): Future[FailureOutcome] {.
    async.} =
  let sourceState = SourceState(
    data: bytes("terminal source"),
    declaredSize: some(15'i64),
    replayable: true,
    terminalStreamReadFailures: (if failClose: 0 else: 1),
    terminalStreamCloseFailures: (if failClose: 1 else: 0)
  )
  let capture = CaptureState(responseCodes: @[Http200])
  let server = startCaptureServer(capture)
  let transport = newWebhookHttpTransport(server.baseUrl())
  let client = newChronosRestClient(transport.asRestTransport())
  client.start()
  try:
    var plan: AttachmentPlan
    plan.add uploadAttachment("terminal.bin", trackedSource(sourceState))
    let body = initMultipartBody(
      %*{}, plan, boundary = "cordnim-source-terminal")
    let pending = client.submit(uploadRequest(body, maxAttempts = 3))
    doAssert await pending.withTimeout(chronos.seconds(2))
    var failed = false
    try:
      discard await pending
    except cordErrors.ValidationError:
      failed = true
    return FailureOutcome(
      failed: failed, opens: sourceState.opens, closes: sourceState.closes)
  finally:
    await client.stop()
    await transport.close()
    await server.closeWait()

proc runClosedPortScenario(): Future[bool] {.async.} =
  let capture = CaptureState()
  let server = startCaptureServer(capture)
  let url = server.baseUrl()
  await server.closeWait()
  let transport = newWebhookHttpTransport(url)
  let callback = transport.asRestTransport()
  try:
    let request = initRawRequest(
      routeKey(hmGet, "/closed"), "/closed")
    try:
      discard await callback(request)
      return false
    except cordErrors.TransportError:
      return true
  finally:
    await transport.close()

proc runBodyLimitScenario(): Future[HttpFailureOutcome] {.async.} =
  let capture = CaptureState(
    responseCodes: @[Http200],
    responseBody: bytes("response exceeds limit")
  )
  let server = startCaptureServer(capture)
  let transport = newWebhookHttpTransport(
    server.baseUrl(), maxResponseBodyBytes = 4)
  let client = newChronosRestClient(transport.asRestTransport())
  client.start()
  try:
    let request = initRawRequest(
      routeKey(hmGet, "/body-limit"),
      "/body-limit",
      meta = testMeta(maxAttempts = 3)
    )
    let pending = client.submit(request)
    doAssert await pending.withTimeout(chronos.seconds(2))
    var failed = false
    try:
      discard await pending
    except cordErrors.DecodeError:
      failed = true
    return HttpFailureOutcome(
      failed: failed, requests: capture.bodies.len)
  finally:
    await client.stop()
    await transport.close()
    await server.closeWait()

proc runMalformedChunkScenario(): Future[HttpFailureOutcome] {.async.} =
  let state = RawPeerState()
  let server = createStreamServer(
    initTAddress("127.0.0.1:0"),
    malformedChunkPeer,
    {ServerFlags.ReuseAddr},
    udata = state
  )
  server.start()
  let transport = newWebhookHttpTransport(
    "http://127.0.0.1:" & $server.localAddress().port)
  let client = newChronosRestClient(transport.asRestTransport())
  client.start()
  try:
    let request = initRawRequest(
      routeKey(hmGet, "/malformed-chunk"),
      "/malformed-chunk",
      meta = testMeta(maxAttempts = 3)
    )
    let pending = client.submit(request)
    doAssert await pending.withTimeout(chronos.seconds(2))
    var failed = false
    try:
      discard await pending
    except cordErrors.DecodeError:
      failed = true
    return HttpFailureOutcome(failed: failed, requests: state.connections)
  finally:
    await client.stop()
    await transport.close()
    server.stop()
    server.close()
    await server.join()

proc runNoContentScenario(): Future[bool] {.async.} =
  let state = RawPeerState()
  let server = createStreamServer(
    initTAddress("127.0.0.1:0"),
    noContentPeer,
    {ServerFlags.ReuseAddr},
    udata = state
  )
  server.start()
  let transport = newWebhookHttpTransport(
    "http://127.0.0.1:" & $server.localAddress().port)
  let client = newChronosRestClient(transport.asRestTransport())
  client.start()
  try:
    let request = initRawRequest(
      routeKey(hmDelete, "/no-content"),
      "/no-content",
      meta = testMeta()
    )
    let pending = client.submit(request)
    if not await pending.withTimeout(chronos.seconds(2)):
      return false
    let response = await pending
    return response.status == 204 and response.body.len == 0 and
      state.connections == 1
  finally:
    await client.stop()
    await transport.close()
    server.stop()
    server.close()
    await server.join()

proc runDnsFailureScenario(): Future[bool] {.async.} =
  let transport = newWebhookHttpTransport(
    "https://cordnim-name-does-not-exist.invalid")
  let callback = transport.asRestTransport()
  try:
    let request = initRawRequest(routeKey(hmGet, "/dns"), "/dns")
    let pending = callback(request)
    doAssert await pending.withTimeout(chronos.seconds(2))
    try:
      discard await pending
      return false
    except cordErrors.TransportError:
      return true
  finally:
    await transport.close()

proc runCancellationScenario(): Future[FailureOutcome] {.async.} =
  let sourceState = SourceState(
    declaredSize: none(int64),
    replayable: true,
    blocked: true,
    readStarted: newFuture[void]("test.rest.http.read-started"),
    blockedRead: newFuture[seq[byte]]("test.rest.http.blocked-read")
  )
  let capture = CaptureState(responseCodes: @[Http200])
  let server = startCaptureServer(capture)
  let transport = newWebhookHttpTransport(server.baseUrl())
  let client = newChronosRestClient(transport.asRestTransport())
  client.start()
  try:
    var plan: AttachmentPlan
    plan.add uploadAttachment("blocked.bin", trackedSource(sourceState))
    let body = initMultipartBody(
      %*{}, plan, boundary = "cordnim-cancel")
    let pending = client.submit(uploadRequest(
      body, cancellationId = some(77'u64)))
    doAssert await sourceState.readStarted.withTimeout(chronos.seconds(2))
    client.cancel(77)
    client.cancel(77)
    doAssert await pending.withTimeout(chronos.seconds(2))
    var failed = false
    try:
      discard await pending
    except CatchableError:
      failed = true
    if not sourceState.blockedRead.finished:
      await sourceState.blockedRead.cancelAndWait()
    return FailureOutcome(
      failed: failed, opens: sourceState.opens, closes: sourceState.closes)
  finally:
    await client.stop()
    await transport.close()
    await server.closeWait()

proc runAuthenticationScenario(): Future[AuthOutcome] {.async.} =
  let botSecret = "bot-auth-sentinel"
  let bearerSecret = "bearer-auth-sentinel"
  let callerSecret = "caller-auth-sentinel"
  let capture = CaptureState(responseCodes: @[
    Http200, Http200, Http200, Http200, Http200])
  let server = startCaptureServer(capture)
  let bot = newDiscordHttpTransport(
    initSecret[BotToken](botSecret), server.baseUrl())
  let bearer = newDiscordOAuthHttpTransport(
    initSecret[OAuthBearerToken](bearerSecret), server.baseUrl())
  let public = newDiscordPublicHttpTransport(server.baseUrl())

  proc request(auth: DiscordAuthRequirement): RawRequest =
    result = initRawRequest(routeKey(hmGet, "/auth"), "/auth")
    result.authRequirement = auth

  try:
    discard await bot.asRestTransport()(request(darBot))
    discard await bot.asRestTransport()(request(darNone))
    discard await bearer.asRestTransport()(request(darOAuthBearer))
    discard await bearer.asRestTransport()(request(darBotOrOAuthBearer))
    discard await public.asRestTransport()(request(darNone))

    try:
      discard await bot.asRestTransport()(request(darOAuthBearer))
    except cordErrors.ValidationError as error:
      result.mismatchRejected = true
      result.diagnosticsSafe = bearerSecret notin error.msg and
        botSecret notin error.msg

    var callerOwned = request(darConfigured)
    callerOwned.headers.add(("Authorization", "Bearer " & callerSecret))
    try:
      discard await public.asRestTransport()(callerOwned)
    except cordErrors.ValidationError as error:
      result.callerHeaderRejected = true
      result.diagnosticsSafe = result.diagnosticsSafe and
        callerSecret notin error.msg
    result.authorizations = capture.authorizations
  finally:
    await bot.close()
    await bearer.close()
    await public.close()
    await server.closeWait()

proc runCredentialInjectionScenario(): Future[CredentialInjectionOutcome] {.
    async.} =
  let capture = CaptureState()
  let server = startCaptureServer(capture)
  try:
    var bot: DiscordHttpTransport
    try:
      bot = newDiscordHttpTransport(
        initSecret[BotToken]("bot-token\r\nX-Injected: yes"),
        server.baseUrl())
    except ValueError as error:
      result.botRejected = true
      doAssert "bot-token" notin error.msg
    if not bot.isNil:
      await bot.close()

    var bearer: DiscordHttpTransport
    try:
      bearer = newDiscordOAuthHttpTransport(
        initSecret[OAuthBearerToken]("bearer-token\r\nX-Injected: yes"),
        server.baseUrl())
    except ValueError as error:
      result.bearerRejected = true
      doAssert "bearer-token" notin error.msg
    if not bearer.isNil:
      await bearer.close()
    result.requests = capture.authorizations.len
  finally:
    await server.closeWait()

func authDomainRequest(path: string, auth: DiscordAuthRequirement,
                       deadline = none(MonoMillis)): RawRequest =
  var meta = testMeta()
  meta.deadline = deadline
  result = initRawRequest(routeKey(hmGet, path), path, meta = meta)
  result.authRequirement = auth

proc runPublicAuthDomainScenario(): Future[AuthDomainOutcome] {.async.} =
  let capture = CaptureState(
    responseCodes: @[Http429],
    responseHeaders: @[
      ("Retry-After", "1"),
      ("X-RateLimit-Global", "true"),
    ])
  let server = startCaptureServer(capture)
  let transport = newDiscordPublicHttpTransport(server.baseUrl())
  let binding = transport.asRestTransport()
  doAssert binding.configuredIdentityIsPublic
  doAssert "RestTransportBinding(public)" == $binding
  let client = newChronosRestClient(binding)
  client.start()
  try:
    let first = await client.submit(authDomainRequest(
      "/public-configured", darConfigured))
    result.statuses.add(first.status)

    let deadline = monotonicMillis() + 100'i64
    let pending = client.submit(authDomainRequest(
      "/public-none", darNone, some(deadline)))
    doAssert await pending.withTimeout(chronos.seconds(2))
    try:
      let response = await pending
      result.statuses.add(response.status)
    except cordErrors.RequestDeadlineError:
      result.blocked = true
    result.requests = capture.bodies.len
    result.authorizations = capture.authorizations
  finally:
    await client.stop()
    await transport.close()
    await server.closeWait()

proc runBotAuthDomainScenario(): Future[AuthDomainOutcome] {.async.} =
  let capture = CaptureState(
    responseCodes: @[Http429, Http429],
    responseHeaders: @[
      ("Retry-After", "1"),
      ("X-RateLimit-Global", "true"),
    ])
  let server = startCaptureServer(capture)
  let transport = newDiscordHttpTransport(
    initSecret[BotToken]("domain-bot-token"), server.baseUrl())
  let binding = transport.asRestTransport()
  doAssert not binding.configuredIdentityIsPublic
  doAssert "domain-bot-token" notin $binding
  doAssert "domain-bot-token" notin repr(binding)
  let client = newChronosRestClient(binding)
  client.start()
  try:
    let configured = await client.submit(authDomainRequest(
      "/bot-configured", darConfigured))
    result.statuses.add(configured.status)

    let public = await client.submit(authDomainRequest(
      "/bot-public", darNone))
    result.statuses.add(public.status)

    let deadline = monotonicMillis() + 100'i64
    let pending = client.submit(authDomainRequest(
      "/bot-explicit", darBot, some(deadline)))
    doAssert await pending.withTimeout(chronos.seconds(2))
    try:
      let response = await pending
      result.statuses.add(response.status)
    except cordErrors.RequestDeadlineError:
      result.blocked = true
    result.requests = capture.bodies.len
    result.authorizations = capture.authorizations
  finally:
    await client.stop()
    await transport.close()
    await server.closeWait()

suite "Discord HTTP transport":
  test "public configured and explicit-none requests share one identity":
    let outcome = waitFor runPublicAuthDomainScenario()
    check outcome.statuses == @[429]
    check outcome.blocked
    check outcome.requests == 1
    check outcome.authorizations == @[""]

  test "bot configured requirements share while public stays independent":
    let outcome = waitFor runBotAuthDomainScenario()
    check outcome.statuses == @[429, 429]
    check outcome.blocked
    check outcome.requests == 2
    check outcome.authorizations == @["Bot domain-bot-token", ""]

  test "operation auth requirements select exactly one transport credential":
    let outcome = waitFor runAuthenticationScenario()
    check outcome.authorizations == @[
      "Bot bot-auth-sentinel",
      "",
      "Bearer bearer-auth-sentinel",
      "Bearer bearer-auth-sentinel",
      "",
    ]
    check outcome.mismatchRejected
    check outcome.callerHeaderRejected
    check outcome.diagnosticsSafe

  test "transport representations never traverse credentials":
    let token = initSecret[OAuthBearerToken]("repr-auth-sentinel")
    let transport = newDiscordOAuthHttpTransport(token)
    check "repr-auth-sentinel" notin $transport
    check "repr-auth-sentinel" notin repr(transport)
    waitFor transport.close()

  test "credential control bytes are rejected before loopback I/O":
    let outcome = waitFor runCredentialInjectionScenario()
    check outcome.botRejected
    check outcome.bearerRejected
    check outcome.requests == 0

  test "rate limit headers are learned dynamically":
    let update = parseRateLimitUpdate(429, [
      ("X-RateLimit-Bucket", "messages"),
      ("X-RateLimit-Limit", "5"),
      ("X-RateLimit-Remaining", "0"),
      ("X-RateLimit-Reset-After", "1.25"),
      ("Retry-After", "2"),
      ("X-RateLimit-Scope", "shared")
    ])
    check update.bucketId == some("messages")
    check update.limit == some(5)
    check update.remaining == some(0)
    check update.resetAfterMs == some(1_250'i64)
    check update.retryAfterMs == some(2_000'i64)
    check update.scope == rlsShared
    check update.wasRateLimited

  test "malformed numeric headers remain unknown":
    let update = parseRateLimitUpdate(200, [
      ("X-RateLimit-Limit", "future"),
      ("X-RateLimit-Reset-After", "later"),
      ("Retry-After", "1e300")
    ])
    check update.limit.isNone
    check update.resetAfterMs.isNone
    check update.retryAfterMs.isNone

  test "negative rate limit delays remain unknown":
    let update = parseRateLimitUpdate(429, [
      ("Retry-After", "-1")
    ])
    check update.retryAfterMs.isNone

  test "absurd finite delays are rejected before integer conversion":
    let boundary = parseRateLimitUpdate(429, [
      ("Retry-After", "9223372036854775")
    ])
    check boundary.retryAfterMs.isNone

    let maximum = parseRateLimitUpdate(429, [
      ("Retry-After", "86400")
    ])
    check maximum.retryAfterMs == some(86_400_000'i64)

    let aboveMaximum = parseRateLimitUpdate(429, [
      ("Retry-After", "86400.001")
    ])
    check aboveMaximum.retryAfterMs.isNone

  test "positive sub-millisecond delays round up conservatively":
    let header = parseRateLimitUpdate(429, [("Retry-After", "0.0009")])
    check header.retryAfterMs == some(1'i64)
    let body = parseRateLimitUpdate(
      429, [], bytes("""{"retry_after":0.0009}"""))
    check body.retryAfterMs == some(1'i64)
    let zero = parseRateLimitUpdate(429, [("Retry-After", "0")])
    check zero.retryAfterMs == some(0'i64)

  test "429 JSON supplies bounded metadata only when headers omit it":
    let update = parseRateLimitUpdate(
      429,
      [],
      bytes("""{"retry_after":1.25,"global":true}""")
    )
    check update.retryAfterMs == some(1_250'i64)
    check update.scope == rlsGlobal

  test "rate limit headers take precedence over a conflicting 429 body":
    let update = parseRateLimitUpdate(
      429,
      [
        ("Retry-After", "2"),
        ("X-RateLimit-Scope", "shared")
      ],
      bytes("""{"retry_after":1,"global":true}""")
    )
    check update.retryAfterMs == some(2_000'i64)
    check update.scope == rlsShared

  test "present malformed headers do not fall back to body values":
    let update = parseRateLimitUpdate(
      429,
      [("Retry-After", "later")],
      bytes("""{"retry_after":1,"global":true}""")
    )
    check update.retryAfterMs.isNone
    check update.scope == rlsGlobal

  test "hostile or oversized 429 fallback delays remain unknown":
    let negative = parseRateLimitUpdate(
      429,
      [],
      bytes("""{"retry_after":-1}""")
    )
    check negative.retryAfterMs.isNone

    let excessive = parseRateLimitUpdate(
      429,
      [],
      bytes("""{"retry_after":86400.001}""")
    )
    check excessive.retryAfterMs.isNone

    let oversizedBody = newSeq[byte](65 * 1_024)
    let oversized = parseRateLimitUpdate(429, [], oversizedBody)
    check oversized.retryAfterMs.isNone
    check oversized.scope == rlsUser

  test "non-429 responses ignore retry metadata in JSON bodies":
    let update = parseRateLimitUpdate(
      200,
      [],
      bytes("""{"retry_after":1,"global":true}""")
    )
    check update.retryAfterMs.isNone
    check update.scope == rlsUser

  test "multipart retries reopen sources and reproduce identical framing":
    let outcome = waitFor runRetryScenario()
    check outcome.status == 200
    check outcome.capture.bodies.len == 2
    check outcome.capture.bodies[0] == outcome.capture.bodies[1]
    check outcome.source.opens == 2
    check outcome.source.closes == 2
    check outcome.source.maxRequested == DefaultUploadChunkBytes
    for index in 0..<2:
      check outcome.capture.contentTypes[index] ==
        "multipart/form-data; boundary=cordnim-retry"
      check outcome.capture.transferEncodings[index].len == 0
      check parseInt(outcome.capture.contentLengths[index]) ==
        outcome.capture.bodies[index].len
    let wire = outcome.capture.bodies[0].text()
    check wire.toLowerAscii().startsWith(
      "--cordnim-retry\r\n" &
      "content-disposition: form-data; name=\"payload_json\"\r\n" &
      "content-type: application/json\r\n\r\n")
    check "Content-Disposition: form-data; name=\"files[0]\"; " &
      "filename=\"blob.bin\"\r\n" in wire
    check "\"id\":0" in wire
    check "\"id\":\"0\"" notin wire
    check "\"is_spoiler\":true" in wire
    check "\"spoiler\":" notin wire
    check wire.endsWith("\r\n--cordnim-retry--\r\n")

  test "unknown source sizes use chunked transfer encoding":
    let outcome = waitFor runUnknownSizeScenario()
    check outcome.status == 200
    check outcome.capture.bodies.len == 1
    check outcome.capture.contentLengths[0].len == 0
    check outcome.capture.transferEncodings[0].toLowerAscii() == "chunked"
    check "streamed-without-a-size" in outcome.capture.bodies[0].text()
    check outcome.source.opens == 1
    check outcome.source.closes == 1

  test "zero-byte uploads retain a framed file part":
    let outcome = waitFor runZeroByteScenario()
    check outcome.status == 200
    check outcome.capture.bodies.len == 1
    check parseInt(outcome.capture.contentLengths[0]) ==
      outcome.capture.bodies[0].len
    let wire = outcome.capture.bodies[0].text()
    check "filename=\"empty.bin\"\r\n" in wire
    check "content-type: application/octet-stream\r\n\r\n\r\n" &
      "--cordnim-empty--\r\n" in wire.toLowerAscii()
    check outcome.source.opens == 1
    check outcome.source.closes == 1

  test "a sized source ending early fails and closes its cursor once":
    let outcome = waitFor runShortSourceScenario()
    check outcome.failed
    check outcome.opens == 1
    check outcome.closes == 1

  test "an explicit upload transport failure opts into retry":
    let outcome = waitFor runRetryableSourceScenario()
    check outcome.status == 200
    check outcome.source.opens == 2
    check outcome.source.closes == 2
    check outcome.capture.bodies.len == 1

  test "source-owned stream failures remain terminal":
    for failClose in [false, true]:
      let outcome = waitFor runTerminalSourceScenario(failClose)
      check outcome.failed
      check outcome.opens == 1
      check outcome.closes == 1

  test "the HTTP adapter translates a closed connection as retryable":
    check waitFor runClosedPortScenario()

  test "response body limit failures remain terminal":
    let outcome = waitFor runBodyLimitScenario()
    check outcome.failed
    check outcome.requests == 1

  test "malformed chunk framing is terminal decode failure":
    let outcome = waitFor runMalformedChunkScenario()
    check outcome.failed
    check outcome.requests == 1

  test "204 without Content-Length completes on a persistent connection":
    check waitFor runNoContentScenario()

  test "address resolution failures are retryable transport failures":
    check waitFor runDnsFailureScenario()

  test "invalid base URL ports fail before address resolution":
    expect ValueError:
      discard newWebhookHttpTransport("https://discord.com:70000")

  test "cancellation closes an active upload cursor exactly once":
    let outcome = waitFor runCancellationScenario()
    check outcome.failed
    check outcome.opens == 1
    check outcome.closes == 1
