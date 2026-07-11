## Chronos-only asynchronous driver for the central REST scheduler.
##
## Requests in the same learned Discord bucket are serialized, while requests
## in independent buckets execute concurrently. Every spawned transport task is
## retained and cancelled or reaped during `stop`.

import std/tables

import chronos

import cordnim/core/errors
import ./[request, scheduler]

type
  TransportResponse* = object ## Response returned by a concrete HTTP adapter.
    status*: int                 ## HTTP status code.
    headers*: seq[(string, string)] ## Response headers after redaction policy.
    body*: seq[byte]             ## Response body bytes.
    rateLimit*: RateLimitUpdate  ## Parsed Discord rate-limit headers.

  RestTransport* = proc(request: RawRequest): Future[TransportResponse]
    {.gcsafe, raises: [].} ## Async HTTP adapter invoked after scheduling.

  ChronosRestClient* = ref object ## Running central scheduler and task owner.
    scheduler: Scheduler
    transport: RestTransport
    wake: AsyncEvent
    pending: Table[ScheduledRequestId, Future[TransportResponse]]
    transportTasks: seq[Future[void]]
    worker: Future[void]
    running: bool

proc monotonicMillis*(): MonoMillis =
  ## Converts the current Chronos monotonic clock to scheduler milliseconds.
  MonoMillis(Moment.now().epochNanoSeconds div 1_000_000)

proc failedResponse(message: string): Future[TransportResponse] =
  result = newFuture[TransportResponse]("cordnim.rest.failed")
  result.fail(newDiscordError(TransportError, message))

proc finishPending(client: ChronosRestClient, id: ScheduledRequestId,
                   response: sink TransportResponse) =
  if client.pending.hasKey(id):
    let promise = client.pending.getOrDefault(id)
    client.pending.del(id)
    if not promise.finished:
      promise.complete(response)

proc failPending(client: ChronosRestClient, id: ScheduledRequestId,
                 message: string) =
  if client.pending.hasKey(id):
    let promise = client.pending.getOrDefault(id)
    client.pending.del(id)
    if not promise.finished:
      promise.fail(newDiscordError(TransportError, message))

proc settleRejections(client: ChronosRestClient) =
  for rejection in client.scheduler.takeRejections():
    case rejection.kind
    of rjkCancelled:
      client.failPending(rejection.id, "REST request was cancelled before dispatch")
    of rjkDeadlineExpired:
      client.failPending(rejection.id, "REST request deadline expired before dispatch")

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
    client.finishPending(scheduled.id, response)
  except CancelledError:
    client.scheduler.complete(scheduled, RateLimitUpdate(), monotonicMillis())
    client.failPending(scheduled.id, "REST transport task was cancelled")
    raise
  except CatchableError:
    let now = monotonicMillis()
    client.scheduler.complete(scheduled, RateLimitUpdate(), now)
    if scheduled.request.meta.retryPolicy.retryTransportErrors and
        client.scheduler.retry(scheduled, now):
      client.wake.fire()
      return
    # Transport exceptions may embed a token-bearing webhook URL. The public
    # failure crosses the redaction boundary using only scheduler metadata.
    client.failPending(scheduled.id, "REST transport failed")
  finally:
    client.wake.fire()

proc reapTasks(client: ChronosRestClient) =
  var active: seq[Future[void]]
  for task in client.transportTasks:
    if not task.finished:
      active.add task
  client.transportTasks = move active

proc waitUntil(client: ChronosRestClient, wakeAt,
               now: MonoMillis): Future[void] {.
               async: (raises: [CancelledError]).} =
  let delay = max(0'i64, wakeAt - now)
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
      client.transportTasks.add task
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
  let id = client.scheduler.enqueue(request, monotonicMillis())
  client.pending[id] = promise
  client.wake.fire()
  promise

proc cancel*(client: ChronosRestClient, cancellationId: uint64) =
  ## Cancels queued requests carrying `cancellationId`.
  client.scheduler.cancel(cancellationId)
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
    await cancelAndWait(client.transportTasks)
  var ids: seq[ScheduledRequestId]
  for id in client.pending.keys:
    ids.add id
  for id in ids:
    client.failPending(id, "REST client stopped before request completion")
  client.transportTasks.setLen(0)

func queuedCount*(client: ChronosRestClient): int =
  ## Returns requests waiting for a bucket or retry deadline.
  client.scheduler.queuedCount

func inFlightCount*(client: ChronosRestClient): int =
  ## Returns requests currently executing in independent buckets.
  client.scheduler.inFlightCount
