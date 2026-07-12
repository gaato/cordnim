## Bounded, in-memory item collectors for one command or interaction flow.
##
## `offer` never waits and reports whether a filter, capacity limit, or stopped
## collector rejected an item. `next` waits for one admitted item, a timeout,
## or shutdown. `stop` wakes pending readers, discards queued items, and joins
## every future owned by the collector.
##
## A collector holds no persistent routing state and does not survive a process
## restart. Use signed component routes for restart-safe `custom_id` dispatch.
## One Chronos event loop owns a collector; callers must not mutate it across
## threads.

import std/options

import chronos

type
  CollectorPredicate*[T] = proc(item: T): bool {.gcsafe, raises: [].}
    ## Filter deciding whether an item offered to a collector is admitted.

  CollectorOfferResult* = enum ## Outcome of a non-blocking `offer` call.
    offerAccepted, ## The item passed the filter and was queued.
    offerRejectedByFilter, ## The predicate refused the item.
    offerRejectedFull, ## The collector was already at its bounded capacity.
    offerRejectedStopped ## `stop` already completed; no items are admitted.

  Collector*[T] = ref object ## Bounded, in-memory item collector for one
    ## short-lived flow.
    queue: AsyncQueue[T]
    predicate: CollectorPredicate[T]
    capacityValue: int
    stopped: bool
    stopEvent: AsyncEvent
    waiters: seq[Future[T]]

proc newCollector*[T](
    capacity: Positive;
    predicate: CollectorPredicate[T] = nil,
): Collector[T] =
  ## Creates an empty collector bounded to `capacity` queued items.
  ##
  ## `predicate`, when supplied, must be pure with respect to concurrent
  ## collector state; a `nil` predicate admits every item.
  Collector[T](
    queue: newAsyncQueue[T](int(capacity)),
    predicate: predicate,
    capacityValue: int(capacity),
    stopEvent: newAsyncEvent(),
  )

func capacity*[T](collector: Collector[T]): int {.raises: [].} =
  ## Returns the bounded capacity configured at construction.
  ##
  ## Chronos 4.2.x's `AsyncQueue.size()` returns `len(maxsize)` instead of
  ## `maxsize` itself, an upstream typo. Capacity is tracked independently
  ## here instead of relying on that call.
  collector.capacityValue

func len*[T](collector: Collector[T]): int {.raises: [].} =
  ## Returns the number of items currently queued and not yet delivered.
  collector.queue.len

func isStopped*[T](collector: Collector[T]): bool {.raises: [].} =
  ## Reports whether `stop` has completed.
  collector.stopped

proc offer*[T](collector: Collector[T]; item: sink T): CollectorOfferResult =
  ## Attempts to admit `item` without blocking.
  ##
  ## Rejection never grows the underlying queue and never reports acceptance
  ## it did not perform.
  if collector.stopped:
    return offerRejectedStopped
  if not collector.predicate.isNil and not collector.predicate(item):
    return offerRejectedByFilter
  try:
    collector.queue.addLastNoWait(item)
    offerAccepted
  except AsyncQueueFullError:
    offerRejectedFull

proc next*[T](
    collector: Collector[T];
    timeout = InfiniteDuration,
): Future[Option[T]] {.async: (raises: [CancelledError]).} =
  ## Waits for the next admitted item.
  ##
  ## Returns `none` when the collector is already stopped, when `stop`
  ## completes while this call is pending, or when `timeout` elapses first.
  ## If the caller cancels the returned future directly, `CancelledError`
  ## propagates instead of being folded into a `none` result.
  if collector.stopped:
    return none(T)

  let popFut = collector.queue.popFirst()
  collector.waiters.add popFut
  let stopFut = collector.stopEvent.wait()
  var timerFut: Future[void]
  if timeout != InfiniteDuration:
    timerFut = sleepAsync(timeout)

  try:
    if timerFut.isNil:
      discard await race(FutureBase(popFut), FutureBase(stopFut))
    else:
      discard await race(FutureBase(popFut), FutureBase(stopFut),
        FutureBase(timerFut))
  finally:
    var remainingWaiters: seq[Future[T]]
    for waiter in collector.waiters:
      if waiter != popFut:
        remainingWaiters.add waiter
    collector.waiters = move remainingWaiters
    var pending: seq[FutureBase]
    if not popFut.finished():
      pending.add FutureBase(popFut)
    if not stopFut.finished():
      pending.add FutureBase(stopFut)
    if not timerFut.isNil and not timerFut.finished():
      pending.add FutureBase(timerFut)
    if pending.len > 0:
      await cancelAndWait(pending)

  if popFut.completed():
    some(popFut.value)
  else:
    none(T)

proc stop*[T](collector: Collector[T]): Future[void] {.async: (raises: []).} =
  ## Idempotently stops the collector, waking every pending `next()` call.
  ##
  ## Items admitted but not yet delivered through `next` are discarded so the
  ## stop contract stays simple and deterministic: every `next` call made
  ## after `stop` is invoked resolves to `none` without consulting the queue,
  ## and every future this collector owned is cancelled and joined, leaving
  ## no orphan future behind. A `next` call already racing a queued item at
  ## the exact moment `stop` runs may still observe the value it had already
  ## won before the stop signal reached it; this is the only case where a
  ## value can outlive a call to `stop`.
  if collector.stopped:
    return
  collector.stopped = true
  collector.stopEvent.fire()
  if collector.waiters.len > 0:
    let pending = collector.waiters
    await cancelAndWait(pending)
  collector.waiters.setLen(0)
  collector.queue.clear()
