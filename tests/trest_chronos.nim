import std/[options, unittest]

import chronos

import cordnim/core/errors as cord_errors
import cordnim/rest

proc fakeTransport(request: RawRequest): Future[TransportResponse]
    {.gcsafe, raises: [].} =
  let future = newFuture[TransportResponse]("fake.transport")
  try:
    future.complete TransportResponse(
      status: 200,
      body: request.body.bodyBytes()
    )
  except CatchableError as error:
    future.fail(error)
  future

proc makeRequest(path: string): RawRequest =
  RawRequest(
    route: routeKey(hmGet, path),
    urlPath: path,
    body: @[byte 1, 2, 3],
    meta: RequestMeta(
      priority: rpNormal,
      retryPolicy: defaultRetryPolicy(),
      idempotency: idSafe
    )
  )

suite "Chronos REST driver":
  test "scheduler waits are duration-safe and chunked":
    check schedulerWaitChunkMs(MonoMillis(100), MonoMillis(40)) == 60
    check schedulerWaitChunkMs(MonoMillis(40), MonoMillis(100)) == 0
    check schedulerWaitChunkMs(
      MonoMillis(high(int64)), MonoMillis(0)) == MaxSchedulerWaitChunkMs
    check schedulerWaitChunkMs(
      MonoMillis(high(int64)), MonoMillis(low(int64))) ==
        MaxSchedulerWaitChunkMs

  test "executes scheduled requests and owns shutdown":
    proc scenario(): Future[TransportResponse] {.async.} =
      let client = newChronosRestClient(fakeTransport)
      client.start()
      let response = await client.submit(makeRequest("/gateway"))
      await client.stop()
      return response
    let response = waitFor scenario()
    check response.status == 200
    check response.body == @[byte 1, 2, 3]

  test "stopped clients fail instead of leaking a future":
    proc scenario(): Future[bool] {.async.} =
      let client = newChronosRestClient(fakeTransport)
      try:
        discard await client.submit(makeRequest("/gateway"))
        return false
      except cord_errors.LifecycleError:
        return true
    check waitFor scenario()

  test "deterministic local failures are terminal":
    type AttemptState = ref object
      attempts: int

    proc scenario(): Future[tuple[failed: bool, attempts: int]] {.async.} =
      let state = AttemptState()
      let transport: RestTransport = proc(
          request: RawRequest): Future[TransportResponse]
          {.gcsafe, raises: [].} =
        discard request
        inc state.attempts
        result = newFuture[TransportResponse]("test.rest.local-failure")
        result.fail(newException(ValueError, "deterministic invalid request"))

      let client = newChronosRestClient(transport)
      client.start()
      var request = makeRequest("/local-failure")
      request.meta.retryPolicy.baseDelayMs = 0
      request.meta.retryPolicy.maxDelayMs = 0
      let pending = client.submit(request)
      doAssert await pending.withTimeout(chronos.seconds(1))
      var failed = false
      try:
        discard await pending
      except cord_errors.ValidationError:
        failed = true
      await client.stop()
      return (failed, state.attempts)

    let outcome = waitFor scenario()
    check outcome.failed
    check outcome.attempts == 1

  test "explicit transport failures follow retry policy":
    type AttemptState = ref object
      attempts: int

    proc scenario(): Future[tuple[status, attempts: int]] {.async.} =
      let state = AttemptState()
      let transport: RestTransport = proc(
          request: RawRequest): Future[TransportResponse]
          {.gcsafe, raises: [].} =
        discard request
        inc state.attempts
        result = newFuture[TransportResponse]("test.rest.retryable-failure")
        if state.attempts < 3:
          result.fail(cord_errors.newDiscordError(
            cord_errors.TransportError, "temporary network failure"))
        else:
          result.complete(TransportResponse(status: 200))

      let client = newChronosRestClient(transport)
      client.start()
      var request = makeRequest("/retryable-failure")
      request.meta.retryPolicy.baseDelayMs = 0
      request.meta.retryPolicy.maxDelayMs = 0
      let response = await client.submit(request)
      await client.stop()
      return (response.status, state.attempts)

    let outcome = waitFor scenario()
    check outcome.status == 200
    check outcome.attempts == 3

  test "cancellation stops a matching in-flight transport idempotently":
    proc scenario(): Future[tuple[
        failed, transportCancelled, drained: bool]] {.async.} =
      let started = newFuture[void]("test.rest.active-started")
      let held = newFuture[TransportResponse]("test.rest.active-held")
      let transport: RestTransport = proc(
          request: RawRequest): Future[TransportResponse]
          {.gcsafe, raises: [].} =
        discard request
        if not started.finished:
          started.complete()
        held

      let client = newChronosRestClient(transport)
      client.start()
      var request = makeRequest("/cancel-active")
      request.meta.cancellationId = some(73'u64)
      let response = client.submit(request)
      await started
      doAssert client.inFlightCount == 1

      client.cancel(73)
      client.cancel(73)
      let finished = await response.withTimeout(chronos.seconds(1))
      var failed = false
      if finished:
        try:
          discard await response
        except cord_errors.RequestCancelledError:
          failed = true

      client.cancel(73)
      await sleepAsync(chronos.milliseconds(1))
      let drained = client.inFlightCount == 0 and client.queuedCount == 0
      let transportCancelled = held.cancelled
      await client.stop()
      return (failed, transportCancelled, drained)

    let result = waitFor scenario()
    check result.failed
    check result.transportCancelled
    check result.drained

  test "stop drains queued ownership and restart cannot run an orphan":
    type AttemptState = ref object
      attempts: int

    proc scenario(): Future[tuple[
        failedFirst, failedQueued, drained, noRestart: bool]] {.async.} =
      let state = AttemptState()
      let started = newFuture[void]("test.rest.stop-started")
      let held = newFuture[TransportResponse]("test.rest.stop-held")
      let transport: RestTransport = proc(
          request: RawRequest): Future[TransportResponse]
          {.gcsafe, raises: [].} =
        discard request
        inc state.attempts
        if state.attempts == 1:
          if not started.finished:
            started.complete()
          held
        else:
          let ready = newFuture[TransportResponse]("test.rest.stop-orphan")
          ready.complete(TransportResponse(status: 200))
          ready

      let client = newChronosRestClient(transport)
      client.start()
      var firstRequest = makeRequest("/stop-drain")
      firstRequest.meta.cancellationId = some(201'u64)
      var queuedRequest = makeRequest("/stop-drain")
      queuedRequest.meta.cancellationId = some(202'u64)
      let first = client.submit(firstRequest)
      await started
      let queued = client.submit(queuedRequest)
      doAssert client.inFlightCount == 1
      doAssert client.queuedCount == 1

      await client.stop()
      var failedFirst = false
      var failedQueued = false
      try:
        discard await first
      except cord_errors.RequestCancelledError:
        failedFirst = true
      try:
        discard await queued
      except cord_errors.LifecycleError:
        failedQueued = true
      let drained = client.inFlightCount == 0 and
        client.queuedCount == 0 and
        client.activeCancellationGroupCount == 0

      client.start()
      await sleepAsync(chronos.milliseconds(10))
      let noRestart = state.attempts == 1 and
        client.inFlightCount == 0 and client.queuedCount == 0
      await client.stop()
      return (failedFirst, failedQueued, drained, noRestart)

    let outcome = waitFor scenario()
    check outcome.failedFirst
    check outcome.failedQueued
    check outcome.drained
    check outcome.noRestart
