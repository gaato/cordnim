## Asynchronous owner that runs Gateway dispatch handlers under an `EventPolicy`.
##
## `dispatch.nim` supplies the pure primitives: the validated `EventPolicy`, the
## stateful `DispatchLaneChooser`, and a synchronous `BoundedQueue`. This module
## provides the asynchronous owner above them. It fans dispatched events across
## one Chronos `AsyncQueue` per lane, runs the user handler on a dedicated worker
## per lane, and preserves the ordering guarantee each policy promises.
##
## Ownership model:
##
## * One Chronos event-loop owner drives a runtime. The unique Gateway reader
##   calls `submit` synchronously; the runtime never blocks that reader on queue
##   capacity, because a blocked reader could not also process heartbeat ACK,
##   RECONNECT, INVALID_SESSION, or close control frames.
## * `start` creates and retains every worker future in a `TaskScope`; no worker
##   is `asyncSpawn`ed and none is left orphaned.
## * The runtime is **not** synchronized for cross-thread access. All mutation of
##   its queues, chooser cursor, and lifecycle flags happens on the owning loop.
##
## Backpressure contract:
##
## When the chosen lane is already at capacity, `submit` returns `dispatchOverloaded`
## instead of silently dropping the event. The runtime never reports admission it
## did not perform. Recovering from overload is the shard owner's responsibility:
## it must abort the connection and RESUME from the last sequence that was
## admitted with `dispatchAccepted`, because an overflowed event was never queued.

import chronos

import ./[dispatch, session]
import ../runtime/task_scope
import ../observability/metrics

type
  DispatchEvent* = object ## One dispatched Gateway event handed to a handler.
    shardId*: ShardId ## Gateway shard the event was received on. Every handler
      ## in a multi-shard process must be able to attribute an event to its
      ## source shard; this is that attribution and is never a secret.
    name*: string ## Discord dispatch event name, e.g. `"MESSAGE_CREATE"`. Used
      ## as low-cardinality diagnostic metadata; never a secret.
    sequence*: GatewaySequence ## Dispatch sequence for resume accounting.
    partitionKey*: uint64 ## Ordering key (for example a guild id) consulted only
      ## by the partitioned policy; ignored by ordered and concurrent policies.
    payload*: string ## Raw event data for the handler. Deliberately excluded
      ## from `DispatchErrorContext` so handler-owned content cannot leak.

  DispatchAdmission* = enum ## Result of a synchronous `submit` call.
    dispatchAccepted, ## The event was enqueued for handler execution.
    dispatchOverloaded, ## The chosen lane was full; caller must abort and RESUME.
    dispatchNotStarted, ## Workers are not started; the event was not enqueued.
    dispatchClosed ## The runtime is closed; no further events are admitted.

  DispatchErrorContext* = object ## Secret-safe description of a handler failure.
    ##
    ## It carries stable event metadata and the raised exception's *type* name,
    ## never the exception message, which may embed request bodies or tokens. The
    ## source `shardId` is retained so a multi-shard error sink can attribute the
    ## failure without inspecting the redacted payload.
    shardId*: ShardId ## Shard the failed event was received on.
    eventName*: string ## Dispatch event name that failed.
    sequence*: GatewaySequence ## Sequence of the failed event.
    partitionKey*: uint64 ## Partition key of the failed event.
    lane*: int ## Zero-based lane that executed the handler.
    exceptionName*: string ## Raised exception type name, for example `"ValueError"`.

  GatewayDispatchHandler* = proc(event: DispatchEvent): Future[void] {.
    closure, gcsafe, raises: [].} ## User handler for one dispatched event. A
    ## returned failed future is isolated per lane; `CancelledError` is shutdown.

  DispatchErrorObserver* = proc(context: DispatchErrorContext) {.
    closure, gcsafe, raises: [].} ## Sink for handler failures. It must not raise
    ## and receives only redaction-safe metadata.

  DispatchEnvelope = object ## Internal queued unit pairing an event with its lane.
    event: DispatchEvent
    lane: int

  GatewayDispatchRuntime* = ref object ## Async owner of policy-bound dispatch lanes.
    handler: GatewayDispatchHandler
    observer: DispatchErrorObserver
    recorder: MetricRecorder
    lanes: seq[AsyncQueue[DispatchEnvelope]]
    laneCapacityValue: int
    chooser: DispatchLaneChooser
    workers: TaskScope
    started: bool
    closed: bool
    closeComplete: AsyncEvent ## Fired once teardown finishes; shared join point.

func initDispatchEvent*(
    name: string;
    shardId: ShardId;
    sequence: GatewaySequence;
    partitionKey: uint64 = 0'u64;
    payload: sink string = "",
): DispatchEvent {.raises: [ValueError].} =
  ## Creates one dispatch event, validating the name once at the input boundary.
  ##
  ## `shardId` binds the event to the shard it arrived on so every handler can
  ## attribute it to a source.
  if name.len == 0:
    raise newException(ValueError, "dispatch event name must not be empty")
  DispatchEvent(
    shardId: shardId,
    name: name,
    sequence: sequence,
    partitionKey: partitionKey,
    payload: payload,
  )

func laneCount*(runtime: GatewayDispatchRuntime): int {.inline, raises: [].} =
  ## Returns the number of ordered lanes, one per worker.
  runtime.lanes.len

func laneCapacity*(runtime: GatewayDispatchRuntime): int {.inline, raises: [].} =
  ## Returns the per-lane bounded capacity.
  ##
  ## Chronos 4.2.x's `AsyncQueue.size()` returns `len(maxsize)` rather than
  ## `maxsize`, an upstream typo, so capacity is tracked here instead of read
  ## back from any lane.
  runtime.laneCapacityValue

func queueDepth*(runtime: GatewayDispatchRuntime): int {.raises: [].} =
  ## Returns the total number of events queued across every lane.
  for lane in runtime.lanes:
    result += lane.len

func aggregateQueueCapacity*(runtime: GatewayDispatchRuntime): int {.
    inline, raises: [].} =
  ## Returns the summed admission ceiling across every lane.
  ##
  ## This equals `laneCapacity * laneCount`. Overload is decided per lane, so a
  ## submit can be rejected while aggregate depth is below this value; it is a
  ## capacity summary, not a global gate.
  runtime.laneCapacityValue * runtime.lanes.len

func workerCount*(runtime: GatewayDispatchRuntime): int {.inline, raises: [].} =
  ## Returns the number of retained worker futures; zero after `close`.
  runtime.workers.len

func isClosed*(runtime: GatewayDispatchRuntime): bool {.inline, raises: [].} =
  ## Reports whether admission has been permanently closed.
  runtime.closed

func isRunning*(runtime: GatewayDispatchRuntime): bool {.inline, raises: [].} =
  ## Reports whether workers are started and admission is still open.
  runtime.started and not runtime.closed

proc newGatewayDispatchRuntime*(
    policy: EventPolicy;
    handler: GatewayDispatchHandler;
    errorObserver: DispatchErrorObserver = nil;
    recorder: MetricRecorder = nil,
): GatewayDispatchRuntime {.raises: [ValueError].} =
  ## Creates a stopped runtime for `policy`, validating inputs once.
  ##
  ## The lane count is derived from the policy so it stays consistent with
  ## `DispatchLaneChooser`: one lane for `orderedEvents`, `maxConcurrent` lanes
  ## for `concurrentEvents`, and `maxPartitions` lanes for `partitionedEvents`.
  ## Call `start` to spawn workers and `close` to release them.
  if handler.isNil:
    raise newException(ValueError, "dispatch handler must not be nil")
  if policy.laneQueueCapacity <= 0:
    raise newException(
      ValueError, "dispatch lane queue capacity must be positive")
  if policy.maxConcurrent <= 0:
    raise newException(ValueError, "dispatch lane count must be positive")

  result = GatewayDispatchRuntime(
    handler: handler,
    observer: errorObserver,
    recorder: recorder,
    laneCapacityValue: policy.laneQueueCapacity,
    chooser: initDispatchLaneChooser(policy),
    workers: newTaskScope(),
    closeComplete: newAsyncEvent(),
  )
  for _ in 0 ..< policy.maxConcurrent:
    result.lanes.add(newAsyncQueue[DispatchEnvelope](policy.laneQueueCapacity))

proc emit(runtime: GatewayDispatchRuntime; name: string; value: float64) {.
    raises: [].} =
  ## Records one metric sample through the injected recorder, if any.
  ##
  ## `MetricRecorder` is a `gcsafe`, non-raising observer contract, so the call
  ## is made directly: it cannot raise into the Gateway reader and needs no
  ## containment or `gcsafe` assertion here.
  if runtime.recorder.isNil:
    return
  runtime.recorder(metricSample(name, value))

proc reportError(
    runtime: GatewayDispatchRuntime;
    envelope: DispatchEnvelope;
    exceptionName: string,
) {.raises: [].} =
  ## Forwards redaction-safe failure metadata to the observer, if any.
  if runtime.observer.isNil:
    return
  runtime.observer(DispatchErrorContext(
    shardId: envelope.event.shardId,
    eventName: envelope.event.name,
    sequence: envelope.event.sequence,
    partitionKey: envelope.event.partitionKey,
    lane: envelope.lane,
    exceptionName: exceptionName,
  ))

proc runLane(
    runtime: GatewayDispatchRuntime;
    lane: int,
) {.async: (raises: []).} =
  ## Serialized consumer for one lane; the source of the per-lane order guarantee.
  ##
  ## A handler failure is caught, reported as metadata, and swallowed so the lane
  ## keeps draining. `CancelledError` from either the queue wait or a handler is
  ## shutdown and ends the worker.
  while true:
    var envelope: DispatchEnvelope
    try:
      envelope = await runtime.lanes[lane].get()
    except CancelledError:
      break
    try:
      await runtime.handler(envelope.event)
    except CancelledError:
      # Cancellation during a handler is shutdown, not a handler defect.
      runtime.emit(handlerCancelledTotal, 1.0)
      break
    except CatchableError as exc:
      # Isolation: report the failure by stable metadata only, never `exc.msg`,
      # then continue draining this lane.
      runtime.reportError(envelope, $exc.name)

proc start*(runtime: GatewayDispatchRuntime) {.raises: [].} =
  ## Spawns and retains one worker future per lane. Idempotent.
  ##
  ## Each worker runs synchronously to its first queue await during this call,
  ## so no event is lost between `start` and the first `submit`. Calling `start`
  ## after `close` is a no-op; a closed runtime admits nothing.
  if runtime.started or runtime.closed:
    return
  runtime.started = true
  for lane in 0 ..< runtime.lanes.len:
    try:
      discard runtime.workers.spawn(runLane(runtime, lane))
    except ValueError:
      # The scope is freshly created and only closed by `close`, which also sets
      # `closed`; the guard above already excludes that path.
      discard

proc submit*(
    runtime: GatewayDispatchRuntime;
    event: sink DispatchEvent,
): DispatchAdmission {.raises: [].} =
  ## Enqueues `event` without blocking and returns the admission outcome.
  ##
  ## This is the Gateway reader's path: it never awaits queue capacity. A full
  ## lane yields `dispatchOverloaded` and the event is not queued; the caller
  ## must abort and RESUME from the last `dispatchAccepted` sequence. After
  ## `close` it yields `dispatchClosed`.
  ##
  ## Before `start` there are no workers draining the lanes, so admission is
  ## refused with `dispatchNotStarted` rather than silently enqueuing work that
  ## nothing would ever process. The caller must `start` the runtime first.
  if runtime.closed:
    return dispatchClosed
  if not runtime.started:
    return dispatchNotStarted
  let lane = runtime.chooser.chooseLane(event.partitionKey)
  try:
    runtime.lanes[lane].putNoWait(DispatchEnvelope(event: event, lane: lane))
  except AsyncQueueFullError:
    return dispatchOverloaded
  runtime.emit(gatewayDispatchQueueDepth, float64(runtime.queueDepth))
  dispatchAccepted

proc close*(runtime: GatewayDispatchRuntime) {.async: (raises: []).} =
  ## Closes admission, cancels and joins every worker, and clears the queues.
  ##
  ## Admission is rejected before the first await, so a `submit` racing `close`
  ## observes `dispatchClosed`. Cancellation propagates into any handler blocked
  ## forever, so a stuck handler cannot prevent shutdown. Idempotent and
  ## join-safe: a concurrent second call awaits the same teardown and returns only
  ## after every worker is cancelled and joined and the queues are cleared, so no
  ## worker future is retained past any caller's return.
  if runtime.closed:
    await noCancel(runtime.closeComplete.wait())
    return
  runtime.closed = true
  await runtime.workers.cancelAndJoin()
  for lane in runtime.lanes:
    lane.clear()
  runtime.closeComplete.fire()
