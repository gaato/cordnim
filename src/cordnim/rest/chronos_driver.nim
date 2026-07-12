## Chronos-only asynchronous driver for the central REST scheduler.
##
## Requests in the same learned Discord bucket are serialized, while requests
## in independent buckets execute concurrently. Every spawned transport task is
## retained and cancelled or reaped during `stop`.

{.experimental: "callOperator".}

import std/[options, tables]

import chronos

import cordnim/core/errors as cordErrors
import ./[request, scheduler]

const
  MaxSchedulerWaitChunkMs* = 60_000'i64
    ## Long scheduler waits are rechecked at least once per minute.

type
  TransportResponse* = object ## Response returned by a concrete HTTP adapter.
    status*: int ## HTTP status code.
    headers*: seq[(string, string)] ## Response headers after redaction policy.
    body*: seq[byte] ## Response body bytes.
    rateLimit*: RateLimitUpdate ## Parsed Discord rate-limit headers.

  RestTransport* = proc(request: RawRequest): Future[TransportResponse]
    {.gcsafe, raises: [].} ## Async HTTP adapter invoked after scheduling.

  RestTransportBinding* = object ## Callable transport plus byte-free scheduler
    ## identity metadata. The boolean says whether `darConfigured` emits no
    ## credential and therefore shares the public/IP rate-limit identity.
    callback: RestTransport
    configuredIdentityIsPublic: bool

  ActiveTransport = object
    cancellationId: Option[uint64]
    future: Future[void]
    cancellationRequested: bool

  ChronosRestClient* = ref object ## Running central scheduler and task owner.
    scheduler: Scheduler
    transport: RestTransport
    configuredIdentityIsPublic: bool
    wake: AsyncEvent
    pending: Table[ScheduledRequestId, Future[TransportResponse]]
    transportTasks: seq[ActiveTransport]
    worker: Future[void]
    running: bool

proc monotonicMillis*(): MonoMillis =
  ## Converts the current Chronos monotonic clock to scheduler milliseconds.
  MonoMillis(Moment.now().epochNanoSeconds div 1_000_000)

proc bindRestTransport*(transport: RestTransport,
                        configuredIdentityIsPublic = false):
                        RestTransportBinding =
  ## Binds one opaque callback to its byte-free scheduler identity fact.
  if transport.isNil:
    raise newException(ValueError, "REST transport must not be nil")
  RestTransportBinding(
    callback: transport,
    configuredIdentityIsPublic: configuredIdentityIsPublic)

proc `()`*(binding: RestTransportBinding,
           request: RawRequest): Future[TransportResponse] {.
           gcsafe, raises: [].} =
  ## Preserves direct callback-style invocation of a bound transport.
  binding.callback(request)

converter toRestTransport*(binding: RestTransportBinding): RestTransport =
  ## Preserves APIs that explicitly accept the legacy callback type.
  binding.callback

func configuredIdentityIsPublic*(binding: RestTransportBinding): bool =
  ## Reports only the scheduler identity fact; no credential bytes are exposed.
  binding.configuredIdentityIsPublic

func `$`*(binding: RestTransportBinding): string =
  ## Omits the opaque callback and anything its environment retains.
  if binding.callback.isNil:
    "RestTransportBinding(nil)"
  elif binding.configuredIdentityIsPublic:
    "RestTransportBinding(public)"
  else:
    "RestTransportBinding(configured)"

func repr*(binding: RestTransportBinding): string =
  ## Uses the callback-free binding representation.
  $binding

func schedulerWaitChunkMs*(wakeAt, now: MonoMillis): int64 =
  ## Returns a Duration-safe, bounded wait chunk for one scheduler poll.
  if wakeAt <= now:
    return 0
  let difference = uint64(int64(wakeAt)) - uint64(int64(now))
  if difference > uint64(MaxSchedulerWaitChunkMs):
    MaxSchedulerWaitChunkMs
  else:
    int64(difference)

proc failedResponse(message: string): Future[TransportResponse] =
  result = newFuture[TransportResponse]("cordnim.rest.failed")
  result.fail(cordErrors.newDiscordError(cordErrors.LifecycleError, message))

proc finishPending(client: ChronosRestClient, id: ScheduledRequestId,
                   response: sink TransportResponse) =
  if client.pending.hasKey(id):
    let promise = client.pending.getOrDefault(id)
    client.pending.del(id)
    if not promise.finished:
      promise.complete(response)

proc failPending(client: ChronosRestClient, id: ScheduledRequestId,
                 error: ref CatchableError) =
  if client.pending.hasKey(id):
    let promise = client.pending.getOrDefault(id)
    client.pending.del(id)
    if not promise.finished:
      promise.fail(error)

proc settleRejections(client: ChronosRestClient) =
  for rejection in client.scheduler.takeRejections():
    case rejection.kind
    of rjkCancelled:
      client.failPending(rejection.id, cordErrors.newDiscordError(
        cordErrors.RequestCancelledError,
        "REST request was cancelled before dispatch"))
    of rjkDeadlineExpired:
      client.failPending(rejection.id, cordErrors.newDiscordError(
        cordErrors.RequestDeadlineError,
        "REST request deadline expired before dispatch"))

func shouldRetry(response: TransportResponse,
                 request: RawRequest): bool =
  # A 429 normally precedes execution at Discord, but the scheduler also accepts
  # custom transports and proxies. Keep every automatic replay behind explicit
  # idempotency evidence rather than assuming all intermediaries are exact.
  request.meta.canRetry and
    (response.status == 429 or
      (response.status >= 500 and response.status <= 599 and
       request.meta.retryPolicy.retryServerErrors))

proc executeOne(client: ChronosRestClient,
                scheduled: ScheduledRequest): Future[void] {.
                async: (raises: [CancelledError]).} =
  try:
    let response = await client.transport(scheduled.request)
    let now = monotonicMillis()
    client.scheduler.complete(scheduled, response.rateLimit, now)
    if response.shouldRetry(scheduled.request) and
        client.scheduler.retry(scheduled, now):
      client.wake.fire()
      return
    client.scheduler.settle(scheduled)
    client.finishPending(scheduled.id, response)
  except CancelledError:
    client.scheduler.complete(scheduled, RateLimitUpdate(), monotonicMillis())
    client.scheduler.settle(scheduled)
    client.failPending(scheduled.id, cordErrors.newDiscordError(
      cordErrors.RequestCancelledError,
      "REST transport task was cancelled"))
    raise
  except cordErrors.TransportError:
    let now = monotonicMillis()
    client.scheduler.complete(scheduled, RateLimitUpdate(), now)
    if scheduled.request.meta.retryPolicy.retryTransportErrors and
        client.scheduler.retry(scheduled, now):
      client.wake.fire()
      return
    client.scheduler.settle(scheduled)
    client.failPending(scheduled.id, cordErrors.newDiscordError(
      cordErrors.TransportError, "REST transport failed"))
  except cordErrors.DiscordError as error:
    client.scheduler.complete(
      scheduled, RateLimitUpdate(), monotonicMillis())
    client.scheduler.settle(scheduled)
    # Concrete transports establish their own redaction boundary before
    # returning a public Cordnim category. Preserve that category and metadata.
    client.failPending(scheduled.id, error)
  except CatchableError:
    # Validation, encoding, body limits, and source-contract violations are
    # deterministic local failures. Replaying them cannot repair the request.
    client.scheduler.complete(
      scheduled, RateLimitUpdate(), monotonicMillis())
    client.scheduler.settle(scheduled)
    # Application-supplied transports may expose arbitrary exception text.
    # Preserve only the terminal local-validation category at this boundary.
    client.failPending(scheduled.id, cordErrors.newDiscordError(
      cordErrors.ValidationError, "REST request validation failed"))
  finally:
    client.wake.fire()

proc reapTasks(client: ChronosRestClient) =
  var active: seq[ActiveTransport]
  for task in client.transportTasks:
    if not task.future.finished:
      active.add task
  client.transportTasks = move active

proc waitUntil(client: ChronosRestClient, wakeAt,
               now: MonoMillis): Future[void] {.
               async: (raises: [CancelledError]).} =
  let delay = schedulerWaitChunkMs(wakeAt, now)
  let wakeFuture = client.wake.wait()
  let timerFuture = sleepAsync(delay.milliseconds)
  discard await one(wakeFuture, timerFuture)
  await cancelAndWait(wakeFuture, timerFuture)

proc workerLoop(client: ChronosRestClient): Future[void] {.
                async: (raises: [CancelledError]).} =
  while client.running:
    client.wake.clear()
    client.reapTasks()
    let now = monotonicMillis()
    let selected = client.scheduler.takeReady(now)
    client.settleRejections()
    case selected.kind
    of tkReady:
      let task = client.executeOne(selected.request)
      client.transportTasks.add ActiveTransport(
        cancellationId: selected.request.request.meta.cancellationId,
        future: task
      )
    of tkWait:
      await client.waitUntil(selected.wakeAt, now)
    of tkIdle:
      await client.wake.wait()

proc newChronosRestClient*(transport: RestTransport): ChronosRestClient =
  ## Creates a stopped client. Call `start` before `submit`.
  if transport.isNil:
    raise newException(ValueError, "REST transport must not be nil")
  ChronosRestClient(
    scheduler: initScheduler(),
    transport: transport,
    wake: newAsyncEvent(),
    pending: initTable[ScheduledRequestId, Future[TransportResponse]]()
  )

proc newChronosRestClient*(binding: RestTransportBinding): ChronosRestClient =
  ## Creates a client that retains the transport's byte-free identity binding.
  result = newChronosRestClient(binding.callback)
  result.configuredIdentityIsPublic = binding.configuredIdentityIsPublic

proc start*(client: ChronosRestClient) =
  ## Starts the single scheduler supervision task.
  if client.running:
    return
  client.running = true
  client.worker = client.workerLoop()

proc submit*(client: ChronosRestClient,
             request: sink RawRequest): Future[TransportResponse] =
  ## Enqueues a request and returns its supervised completion future.
  if not client.running:
    return failedResponse("REST client is not running")
  let promise = newFuture[TransportResponse]("cordnim.rest.submit")
  let id = client.scheduler.enqueue(
    request, monotonicMillis(), client.configuredIdentityIsPublic)
  client.pending[id] = promise
  client.wake.fire()
  promise

proc cancel*(client: ChronosRestClient, cancellationId: uint64) =
  ## Cancels queued and active requests carrying `cancellationId`.
  client.scheduler.cancel(cancellationId)
  for active in client.transportTasks.mitems:
    if active.cancellationId == some(cancellationId) and
        not active.future.finished and not active.cancellationRequested:
      active.cancellationRequested = true
      active.future.cancelSoon()
  client.wake.fire()

proc stop*(client: ChronosRestClient): Future[void] {.
           async: (raises: []).} =
  ## Stops the worker, cancels child transports, and fails pending callers.
  if not client.running:
    return
  client.running = false
  client.wake.fire()
  if not client.worker.isNil:
    await client.worker.cancelAndWait()
  if client.transportTasks.len > 0:
    var futures: seq[Future[void]]
    for active in client.transportTasks:
      futures.add active.future
    await cancelAndWait(futures)
  var ids: seq[ScheduledRequestId]
  for id in client.pending.keys:
    ids.add id
  for id in ids:
    client.failPending(id, cordErrors.newDiscordError(
      cordErrors.LifecycleError,
      "REST client stopped before request completion"))
  client.transportTasks.setLen(0)
  # Queued requests have now had their public promises failed. Drop all bucket,
  # cancellation, and reservation state so a later `start` cannot execute an
  # orphan whose consumer no longer exists.
  client.scheduler = initScheduler()

func queuedCount*(client: ChronosRestClient): int =
  ## Returns requests waiting for a bucket or retry deadline.
  client.scheduler.queuedCount

func inFlightCount*(client: ChronosRestClient): int =
  ## Returns requests currently executing in independent buckets.
  client.scheduler.inFlightCount

func activeCancellationGroupCount*(client: ChronosRestClient): int =
  ## Returns live cancellation groups retained by the running scheduler.
  client.scheduler.activeCancellationGroupCount

func isRunning*(client: ChronosRestClient): bool =
  ## Reports whether the scheduler worker is currently owned and running.
  not client.isNil and client.running
