## Global IDENTIFY budget and concurrency-bucket coordination.

import ./session

const identifyBucketIntervalMs* = 5_000'i64 ## Minimum interval between
  ## IDENTIFYs in one concurrency bucket.

type
  SessionStartLimit* = object ## Discord's `/gateway/bot` session-start limits.
    total*: int ## IDENTIFY allowance available after a full reset.
    remaining*: int ## IDENTIFY operations left in the current window.
    resetAfterMs*: int64 ## Milliseconds until Discord resets the allowance;
                         ## zero means no future deadline was supplied.
    maxConcurrency*: uint16 ## Number of independent IDENTIFY buckets.

  IdentifyLease* = object ## Successful reservation of one IDENTIFY operation.
    shardId*: ShardId ## Shard permitted to identify.
    bucket*: uint16 ## Discord concurrency bucket reserved by the shard.
    acquiredAtMs*: int64 ## Monotonic acquisition time in milliseconds.
    nextAvailableAtMs*: int64 ## Earliest next IDENTIFY time for this bucket.

  IdentifyAcquireKind* = enum ## Outcome of a non-blocking IDENTIFY reservation.
    identifyAcquired, ## A lease was issued and budget consumed.
    identifyBudgetExhausted, ## Global session-start allowance is exhausted.
    identifyBucketCoolingDown ## The shard's concurrency bucket is not ready.

  IdentifyAcquireResult* = object ## Lease or retry time from `tryAcquire`.
    case kind*: IdentifyAcquireKind ## Selects lease or retry data.
    of identifyAcquired:
      lease*: IdentifyLease ## Reserved IDENTIFY lease.
    of identifyBudgetExhausted, identifyBucketCoolingDown:
      retryAtMs*: int64 ## Earliest monotonic time at which retry may succeed.

  IdentifyCoordinator* = object ## In-memory coordinator protecting Discord
    ## IDENTIFY limits. It is process-local and requires serialized mutation by
    ## one owner; it does not coordinate tasks or processes internally.
    total: int
    remaining: int
    resetAtMs: int64
    resetAfterMs: int64
    maxConcurrency: uint16
    bucketNextMs: seq[int64]

proc validate(limit: SessionStartLimit) =
  if limit.total < 0:
    raise newException(ValueError, "session start total must not be negative")
  if limit.remaining < 0 or limit.remaining > limit.total:
    raise newException(
      ValueError,
      "session start remaining must be within total",
    )
  if limit.resetAfterMs < 0:
    raise newException(
      ValueError,
      "session start reset duration must not be negative",
    )
  if limit.maxConcurrency == 0:
    raise newException(ValueError, "max concurrency must be at least one")

proc initIdentifyCoordinator*(
    limit: SessionStartLimit;
    nowMs: int64,
): IdentifyCoordinator =
  ## Initializes a coordinator from fresh `/gateway/bot` limits.
  ##
  ## Raises `ValueError` for internally inconsistent limit values.
  validate(limit)
  let resetAtMs =
    if limit.resetAfterMs == 0: high(int64)
    else: nowMs + limit.resetAfterMs
  IdentifyCoordinator(
    total: limit.total,
    remaining: limit.remaining,
    resetAtMs: resetAtMs,
    resetAfterMs: limit.resetAfterMs,
    maxConcurrency: limit.maxConcurrency,
    bucketNextMs: newSeq[int64](int(limit.maxConcurrency)),
  )

proc refresh*(
    coordinator: var IdentifyCoordinator;
    limit: SessionStartLimit;
    nowMs: int64,
) =
  ## Replaces server limits and rebuilds buckets if concurrency changed.
  validate(limit)
  coordinator.total = limit.total
  coordinator.remaining = limit.remaining
  coordinator.resetAtMs =
    if limit.resetAfterMs == 0: high(int64)
    else: nowMs + limit.resetAfterMs
  coordinator.resetAfterMs = limit.resetAfterMs
  # Keep per-bucket cooldowns when the modulo topology is unchanged. Refreshing
  # the global counters must not enable an early IDENTIFY burst in a live
  # bucket.
  if coordinator.maxConcurrency != limit.maxConcurrency:
    coordinator.maxConcurrency = limit.maxConcurrency
    coordinator.bucketNextMs = newSeq[int64](int(limit.maxConcurrency))

proc resetBudgetIfNeeded(
    coordinator: var IdentifyCoordinator;
    nowMs: int64,
) {.raises: [].} =
  if coordinator.resetAfterMs > 0 and nowMs >= coordinator.resetAtMs:
    coordinator.remaining = coordinator.total
    coordinator.resetAtMs = nowMs + coordinator.resetAfterMs

proc tryAcquire*(
    coordinator: var IdentifyCoordinator;
    shardId: ShardId;
    nowMs: int64,
): IdentifyAcquireResult {.raises: [].} =
  ## Attempts to reserve one IDENTIFY without sleeping or exceeding limits.
  ##
  ## An acquired lease consumes budget permanently. Callers must not refund it
  ## after transport failure because Discord may already have seen the request.
  coordinator.resetBudgetIfNeeded(nowMs)
  if coordinator.remaining == 0:
    return IdentifyAcquireResult(
      kind: identifyBudgetExhausted,
      retryAtMs: coordinator.resetAtMs,
    )

  # Discord assigns shard n to `n mod max_concurrency`; changing this formula
  # would permit concurrent IDENTIFYs in a server-defined shared bucket.
  let bucket = uint16(shardId) mod coordinator.maxConcurrency
  let nextAt = coordinator.bucketNextMs[int(bucket)]
  if nowMs < nextAt:
    return IdentifyAcquireResult(
      kind: identifyBucketCoolingDown,
      retryAtMs: nextAt,
    )

  # A reserved IDENTIFY is intentionally non-refundable: after transport starts,
  # the client cannot prove that Discord did not consume the attempt.
  coordinator.remaining.dec
  coordinator.bucketNextMs[int(bucket)] = nowMs + identifyBucketIntervalMs
  IdentifyAcquireResult(
    kind: identifyAcquired,
    lease: IdentifyLease(
      shardId: shardId,
      bucket: bucket,
      acquiredAtMs: nowMs,
      nextAvailableAtMs: nowMs + identifyBucketIntervalMs,
    ),
  )

func remaining*(coordinator: IdentifyCoordinator): int {.inline, raises: [].} =
  ## Returns the IDENTIFY allowance left in the current window.
  coordinator.remaining

func resetAtMs*(coordinator: IdentifyCoordinator): int64 {.
    inline, raises: [].} =
  ## Returns the monotonic time at which local budget resets.
  coordinator.resetAtMs

func maxConcurrency*(coordinator: IdentifyCoordinator): uint16 {.
    inline, raises: [].} =
  ## Returns the number of server-defined IDENTIFY buckets.
  coordinator.maxConcurrency
