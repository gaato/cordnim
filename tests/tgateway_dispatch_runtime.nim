## Deterministic ORC tests for the asynchronous Gateway dispatch runtime.
##
## Every test drives the single Chronos event loop with `waitFor` on a signal a
## handler fires, so there is no reliance on wall-clock time or sleep. Capacity
## and overload cases fill lanes synchronously before any poll, which keeps the
## worker parked and the queue depth exact.

import std/[strutils, tables]

import chronos

import cordnim/gateway/[dispatch, dispatch_runtime, session]
import cordnim/observability/metrics

type Probe = ref object ## Shared observation state captured by the test handler.
  started: int ## Handlers that have entered.
  cancelled: int ## Handlers whose `CancelledError` path ran.
  processed: seq[DispatchEvent] ## Events completed, in completion order.
  errors: seq[DispatchErrorContext] ## Reported handler failures.
  samples: seq[MetricSample] ## Metric observations.
  gates: Table[uint64, AsyncEvent] ## Per-partition blocking gates.
  startedReached: AsyncEvent ## Fired once `started == startTarget`.
  finishedReached: AsyncEvent ## Fired once `processed.len == finishTarget`.
  progressReached: AsyncEvent ## Fired when a `progressPartition` event finishes.
  boomName: string ## Event name whose handler raises.
  startTarget: int ## Started count that fires `startedReached`.
  finishTarget: int ## Processed count that fires `finishedReached`.
  wantsProgress: bool ## Whether to fire `progressReached`.
  progressPartition: uint64 ## Partition whose completion fires `progressReached`.

proc newProbe(): Probe =
  Probe(
    startedReached: newAsyncEvent(),
    finishedReached: newAsyncEvent(),
    progressReached: newAsyncEvent(),
  )

proc install(probe: Probe): GatewayDispatchHandler =
  ## Builds the configurable handler closure shared by every test.
  result = proc(event: DispatchEvent): Future[void] {.async.} =
    inc probe.started
    if probe.startTarget > 0 and probe.started == probe.startTarget:
      probe.startedReached.fire()
    if probe.boomName.len > 0 and event.name == probe.boomName:
      # The message deliberately embeds the payload to prove it never leaks.
      raise newException(ValueError, "leaked-" & event.payload)
    if probe.gates.hasKey(event.partitionKey):
      try:
        await probe.gates[event.partitionKey].wait()
      except CancelledError:
        inc probe.cancelled
        raise
    probe.processed.add event
    if probe.wantsProgress and event.partitionKey == probe.progressPartition:
      probe.progressReached.fire()
    if probe.finishTarget > 0 and probe.processed.len == probe.finishTarget:
      probe.finishedReached.fire()

proc makeObserver(probe: Probe): DispatchErrorObserver =
  result = proc(ctx: DispatchErrorContext) {.gcsafe, raises: [].} =
    probe.errors.add ctx

proc makeRecorder(probe: Probe): MetricRecorder =
  result = proc(sample: MetricSample) {.gcsafe, raises: [].} =
    probe.samples.add sample

proc ev(
    name: string; seqNo: int; part: uint64 = 0'u64;
    shard: uint16 = 0'u16): DispatchEvent =
  initDispatchEvent(name, ShardId(shard), GatewaySequence(seqNo), part)

proc evp(
    name: string; seqNo: int; part: uint64; payload: string;
    shard: uint16 = 0'u16): DispatchEvent =
  initDispatchEvent(name, ShardId(shard), GatewaySequence(seqNo), part, payload)

proc partitionSequences(probe: Probe; part: uint64): seq[int64] =
  for event in probe.processed:
    if event.partitionKey == part:
      result.add event.sequence.toInt64

block ordered_policy_preserves_global_order:
  let probe = newProbe()
  probe.finishTarget = 8
  let rt = newGatewayDispatchRuntime(orderedPolicy(16), install(probe))
  rt.start()
  doAssert rt.laneCount == 1
  doAssert rt.workerCount == 1
  for i in 1 .. 8:
    doAssert rt.submit(ev("ORDERED", i)) == dispatchAccepted
  waitFor probe.finishedReached.wait()
  waitFor rt.close()

  var sequences: seq[int64]
  for event in probe.processed:
    sequences.add event.sequence.toInt64
  doAssert sequences == @[1'i64, 2, 3, 4, 5, 6, 7, 8]

block partition_order_preserved_while_other_partition_progresses:
  let probe = newProbe()
  probe.gates[0'u64] = newAsyncEvent() # partition 0 is held; partition 1 is free
  probe.wantsProgress = true
  probe.progressPartition = 1'u64
  probe.finishTarget = 4
  let rt = newGatewayDispatchRuntime(partitionedPolicy(8, 2), install(probe))
  rt.start()
  doAssert rt.laneCount == 2

  # Partition 0 keeps ascending sequences 1, 3, 4; partition 1 carries only 2.
  doAssert rt.submit(ev("A", 1, 0'u64)) == dispatchAccepted
  doAssert rt.submit(ev("A", 3, 0'u64)) == dispatchAccepted
  doAssert rt.submit(ev("A", 4, 0'u64)) == dispatchAccepted
  doAssert rt.submit(ev("B", 2, 1'u64)) == dispatchAccepted

  # Partition 1 makes progress even though partition 0 is fully blocked.
  waitFor probe.progressReached.wait()
  doAssert probe.processed.len == 1
  doAssert probe.processed[0].partitionKey == 1'u64
  doAssert probe.partitionSequences(0'u64).len == 0

  probe.gates[0'u64].fire()
  waitFor probe.finishedReached.wait()
  waitFor rt.close()

  # Partition 0 was delivered strictly in submission order behind its block.
  doAssert probe.partitionSequences(0'u64) == @[1'i64, 3, 4]
  doAssert probe.partitionSequences(1'u64) == @[2'i64]

block concurrent_policy_honors_max_concurrency:
  let probe = newProbe()
  probe.gates[0'u64] = newAsyncEvent()
  probe.startTarget = 3
  probe.finishTarget = 6
  let rt = newGatewayDispatchRuntime(concurrentPolicy(8, 3), install(probe))
  rt.start()
  doAssert rt.laneCount == 3
  doAssert rt.workerCount == 3
  for i in 1 .. 6:
    doAssert rt.submit(ev("C", i)) == dispatchAccepted

  # Exactly `maxConcurrent` handlers run at once; the rest wait behind them.
  waitFor probe.startedReached.wait()
  doAssert probe.started == 3
  doAssert probe.processed.len == 0

  probe.gates[0'u64].fire()
  waitFor probe.finishedReached.wait()
  doAssert probe.processed.len == 6
  waitFor rt.close()

block admission_stops_exactly_at_capacity:
  let probe = newProbe()
  let rt = newGatewayDispatchRuntime(orderedPolicy(3), install(probe))
  rt.start()
  doAssert rt.laneCapacity == 3
  doAssert rt.aggregateQueueCapacity == 3
  # No poll happens between submits, so the parked worker never drains a slot.
  for i in 1 .. 3:
    doAssert rt.submit(ev("CAP", i)) == dispatchAccepted
  doAssert rt.queueDepth == 3
  doAssert rt.submit(ev("CAP", 4)) == dispatchOverloaded
  doAssert rt.queueDepth == 3
  waitFor rt.close()
  doAssert rt.queueDepth == 0

block full_lane_returns_overloaded_and_recovers_after_drain:
  let probe = newProbe()
  probe.gates[0'u64] = newAsyncEvent()
  probe.startTarget = 1
  let rt = newGatewayDispatchRuntime(orderedPolicy(2), install(probe))
  rt.start()
  doAssert rt.submit(ev("A", 1)) == dispatchAccepted
  doAssert rt.submit(ev("B", 2)) == dispatchAccepted
  doAssert rt.submit(ev("C", 3)) == dispatchOverloaded
  doAssert rt.queueDepth == 2

  # Draining one event into a blocked handler frees exactly one lane slot.
  waitFor probe.startedReached.wait()
  doAssert rt.queueDepth == 1
  doAssert rt.submit(ev("D", 4)) == dispatchAccepted
  doAssert rt.queueDepth == 2

  probe.gates[0'u64].fire()
  waitFor rt.close()

block closed_runtime_rejects_admission:
  let probe = newProbe()
  let rt = newGatewayDispatchRuntime(orderedPolicy(4), install(probe))
  rt.start()
  waitFor rt.close()
  doAssert rt.isClosed
  doAssert not rt.isRunning
  doAssert rt.submit(ev("AFTER", 1)) == dispatchClosed
  doAssert rt.workerCount == 0

block handler_failure_is_isolated_and_reported_without_secrets:
  let probe = newProbe()
  probe.boomName = "BOOM"
  probe.finishTarget = 2
  let rt = newGatewayDispatchRuntime(
    orderedPolicy(8), install(probe), makeObserver(probe))
  rt.start()
  doAssert rt.submit(
    evp("BOOM", 1, 0'u64, "supersecrettoken", shard = 7)) == dispatchAccepted
  doAssert rt.submit(ev("OK", 2)) == dispatchAccepted
  doAssert rt.submit(ev("OK", 3)) == dispatchAccepted

  waitFor probe.finishedReached.wait()
  waitFor rt.close()

  # The failing event never reaches `processed`, and the lane kept running.
  var sequences: seq[int64]
  for event in probe.processed:
    sequences.add event.sequence.toInt64
  doAssert sequences == @[2'i64, 3]

  doAssert probe.errors.len == 1
  let context = probe.errors[0]
  doAssert context.eventName == "BOOM"
  doAssert context.sequence.toInt64 == 1
  doAssert context.exceptionName == "ValueError"
  # The source shard is carried through so a multi-shard sink can attribute it.
  doAssert context.shardId == ShardId(7)
  # No field, including the rendered object, exposes the exception message.
  doAssert context.eventName.find("supersecret") == -1
  doAssert context.exceptionName.find("supersecret") == -1
  doAssert ($context).find("supersecret") == -1

block close_cancels_a_blocked_handler:
  let probe = newProbe()
  probe.gates[0'u64] = newAsyncEvent() # never fired
  probe.startTarget = 1
  let rt = newGatewayDispatchRuntime(
    orderedPolicy(4), install(probe), recorder = makeRecorder(probe))
  rt.start()
  doAssert rt.submit(ev("BLOCK", 1)) == dispatchAccepted
  waitFor probe.startedReached.wait()
  doAssert probe.processed.len == 0

  # A handler blocked forever must not stop close from completing.
  waitFor rt.close()
  doAssert rt.isClosed
  doAssert rt.workerCount == 0
  doAssert probe.cancelled == 1
  doAssert probe.processed.len == 0

  var cancelSamples = 0
  for sample in probe.samples:
    if sample.name == handlerCancelledTotal:
      inc cancelSamples
  doAssert cancelSamples == 1

block close_retains_no_workers:
  let probe = newProbe()
  let rt = newGatewayDispatchRuntime(partitionedPolicy(4, 3), install(probe))
  rt.start()
  doAssert rt.workerCount == 3
  waitFor rt.close()
  doAssert rt.workerCount == 0

block start_and_close_are_idempotent:
  let probe = newProbe()
  let rt = newGatewayDispatchRuntime(concurrentPolicy(4, 2), install(probe))
  rt.start()
  rt.start() # second start must not spawn duplicate workers
  doAssert rt.workerCount == 2
  waitFor rt.close()
  doAssert rt.workerCount == 0
  waitFor rt.close() # second close must not raise
  doAssert rt.isClosed
  # A runtime closed before ever starting is still safe.
  let never = newGatewayDispatchRuntime(orderedPolicy(2), install(newProbe()))
  never.start() # closed-before-start is impossible here, but start stays a no-op
  waitFor never.close()
  doAssert never.workerCount == 0

block recorder_observes_queue_depth_on_admission:
  let probe = newProbe()
  let rt = newGatewayDispatchRuntime(
    orderedPolicy(8), install(probe), recorder = makeRecorder(probe))
  rt.start()
  for i in 1 .. 3:
    doAssert rt.submit(ev("METRIC", i)) == dispatchAccepted

  var depths: seq[float64]
  for sample in probe.samples:
    if sample.name == gatewayDispatchQueueDepth:
      depths.add sample.value
  doAssert depths == @[1.0, 2.0, 3.0]
  waitFor rt.close()

block submit_before_start_is_rejected:
  # Pre-start submission must be explicit: nothing is enqueued into lanes that no
  # worker is draining, so the event cannot be silently lost until a later start.
  let probe = newProbe()
  let rt = newGatewayDispatchRuntime(orderedPolicy(4), install(probe))
  doAssert not rt.isRunning
  doAssert rt.submit(ev("EARLY", 1)) == dispatchNotStarted
  doAssert rt.queueDepth == 0
  # After starting, the same event is admitted normally.
  probe.finishTarget = 1
  rt.start()
  doAssert rt.submit(ev("EARLY", 1)) == dispatchAccepted
  waitFor probe.finishedReached.wait()
  waitFor rt.close()
  doAssert probe.processed.len == 1

block concurrent_close_is_join_safe:
  # A blocked handler holds the first close in cancel-and-join; a concurrent
  # second close must await the same teardown, not return early with workers left.
  let probe = newProbe()
  probe.gates[0'u64] = newAsyncEvent() # handler blocks forever
  probe.startTarget = 1
  let rt = newGatewayDispatchRuntime(orderedPolicy(4), install(probe))
  rt.start()
  doAssert rt.submit(ev("BLOCK", 1)) == dispatchAccepted
  waitFor probe.startedReached.wait() # the handler is running and blocked
  let first = rt.close()
  let second = rt.close()
  waitFor second # the second caller returns only after teardown completes
  doAssert rt.workerCount == 0
  waitFor first
  doAssert rt.workerCount == 0
  doAssert rt.isClosed

echo "tgateway_dispatch_runtime: all blocks passed"
