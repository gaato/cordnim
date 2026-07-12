## Bounded event queues and explicit Gateway handler concurrency policies.

import std/[deques, options]

type
  EventPolicyKind* = enum ## Ordering model applied to dispatched Gateway
    ## events.
    orderedEvents, ## Deliver all events through one ordered lane.
    concurrentEvents, ## Round-robin events across a bounded lane set.
    partitionedEvents ## Keep partitions ordered across concurrent execution.

  EventPolicy* = object ## Validated dispatch limits used by a Gateway runtime.
    kind*: EventPolicyKind ## Ordering model for event handlers.
    laneQueueCapacity*: int ## Maximum events queued *per lane* before that lane
      ## applies backpressure. The runtime allocates this depth to every lane, so
      ## the aggregate ceiling is `laneQueueCapacity * <lane count>`, not this
      ## value. Named per-lane to keep that invariant unambiguous.
    maxConcurrent*: int ## Maximum handler lanes active at once.
    maxPartitions*: int ## Number of stable partition lanes.

  BoundedQueue*[T] = object ## FIFO that rejects writes at fixed capacity.
    capacity: int
    values: Deque[T]

  DispatchLaneChooser* = object ## Stateful lane selector for an `EventPolicy`.
    policy: EventPolicy
    nextConcurrentLane: int

func orderedPolicy*(laneQueueCapacity: Positive): EventPolicy {.raises: [].} =
  ## Creates a single-lane policy that preserves global event order.
  ##
  ## With one lane, `laneQueueCapacity` is also the aggregate admission ceiling.
  EventPolicy(
    kind: orderedEvents,
    laneQueueCapacity: int(laneQueueCapacity),
    maxConcurrent: 1,
    maxPartitions: 1,
  )

func concurrentPolicy*(
    laneQueueCapacity, maxConcurrent: Positive,
): EventPolicy {.raises: [].} =
  ## Creates a round-robin policy with at most `maxConcurrent` handler lanes.
  ##
  ## `laneQueueCapacity` bounds each lane independently; the aggregate ceiling is
  ## `laneQueueCapacity * maxConcurrent`.
  EventPolicy(
    kind: concurrentEvents,
    laneQueueCapacity: int(laneQueueCapacity),
    maxConcurrent: int(maxConcurrent),
    maxPartitions: 1,
  )

func partitionedPolicy*(
    laneQueueCapacity, maxPartitions: Positive,
): EventPolicy {.raises: [].} =
  ## Creates a policy that maps equal partition keys to the same ordered lane.
  ##
  ## `laneQueueCapacity` bounds each partition lane independently; the aggregate
  ## ceiling is `laneQueueCapacity * maxPartitions`.
  EventPolicy(
    kind: partitionedEvents,
    laneQueueCapacity: int(laneQueueCapacity),
    maxConcurrent: int(maxPartitions),
    maxPartitions: int(maxPartitions),
  )

func initBoundedQueue*[T](capacity: Positive): BoundedQueue[T] {.raises: [].} =
  ## Creates an empty queue whose capacity cannot grow implicitly.
  BoundedQueue[T](capacity: int(capacity), values: initDeque[T]())

proc tryAdd*[T](queue: var BoundedQueue[T]; value: sink T): bool {.
    raises: [].} =
  ## Adds `value`, returning false without mutation when the queue is full.
  if queue.values.len >= queue.capacity:
    return false
  queue.values.addLast(value)
  true

proc popFirst*[T](queue: var BoundedQueue[T]): Option[T] {.raises: [].} =
  ## Removes the oldest value, or returns `none` when the queue is empty.
  if queue.values.len == 0:
    none(T)
  else:
    some(queue.values.popFirst())

func len*[T](queue: BoundedQueue[T]): int {.inline, raises: [].} =
  ## Returns the number of queued values.
  queue.values.len

func isFull*[T](queue: BoundedQueue[T]): bool {.inline, raises: [].} =
  ## Tests whether another value would exceed the fixed capacity.
  queue.values.len >= queue.capacity

proc clear*[T](queue: var BoundedQueue[T]) {.raises: [].} =
  ## Removes every queued value while retaining the configured capacity.
  queue.values.clear()

func initDispatchLaneChooser*(policy: EventPolicy): DispatchLaneChooser {.
    raises: [].} =
  ## Creates a lane selector whose round-robin cursor starts at lane zero.
  DispatchLaneChooser(policy: policy)

proc chooseLane*(
    chooser: var DispatchLaneChooser;
    partitionKey: uint64,
): int {.raises: [].} =
  ## Selects a stable zero-based lane according to the configured policy.
  case chooser.policy.kind
  of orderedEvents:
    result = 0
  of concurrentEvents:
    result = chooser.nextConcurrentLane
    chooser.nextConcurrentLane =
      (chooser.nextConcurrentLane + 1) mod chooser.policy.maxConcurrent
  of partitionedEvents:
    # Modulo mapping is stable for a fixed partition count, preserving order
    # for events from the same guild without retaining an unbounded key table.
    result = int(partitionKey mod uint64(chooser.policy.maxPartitions))
