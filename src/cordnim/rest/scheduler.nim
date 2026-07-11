## Deterministic core for Discord REST rate-limit scheduling.
##
## This module intentionally performs no sleeping and owns no async runtime. A
## single Chronos task drives it by calling `takeReady`, executing the returned
## request, then applying Discord's response headers with `complete`.

import std/[algorithm, hashes, options, tables]

import ./request

type
  ScheduledRequestId* = distinct uint64
    ## Process-local identity assigned when a request enters the scheduler.

  RateLimitScope* = enum ## Discord scope reported for a rate limit.
    rlsUser,   ## Limit applies to the current bot or user identity.
    rlsShared, ## Limit is shared by a resource such as a webhook.
    rlsGlobal  ## Limit blocks every request for the current identity.

  RateLimitUpdate* = object ## Rate-limit facts learned from one response.
    bucketId*: Option[string] ## Discord's opaque bucket identifier.
    limit*: Option[int] ## Maximum requests in the reported window.
    remaining*: Option[int] ## Requests remaining in the current window.
    resetAfterMs*: Option[int64] ## Relative bucket reset delay.
    retryAfterMs*: Option[int64] ## Relative delay from an HTTP 429.
    scope*: RateLimitScope ## Scope associated with a rate-limited response.
    wasRateLimited*: bool ## Whether the response status was HTTP 429.

  ScheduledRequest* = object ## Request selected for one transport attempt.
    id*: ScheduledRequestId ## Stable identity across retries.
    request*: RawRequest ## Request body and execution policy.
    attempt*: int ## One-based transport attempt number.

  QueueEntry = object
    request: ScheduledRequest
    sequence: uint64
    readyAt: MonoMillis

  BucketState = object
    limit: Option[int]
    remaining: Option[int]
    resetAt: Option[MonoMillis]
    queue: seq[QueueEntry]
    inFlight: int

  Scheduler* = object
    ## Deterministic mutable state for all REST buckets and queued requests.
    nextId: uint64
    nextSequence: uint64
    routeBuckets: Table[string, string]
    buckets: Table[string, BucketState]
    cancelled: Table[uint64, bool]
    globalResetAt: Option[MonoMillis]
    rejections: seq[RejectedRequest]

  RejectionKind* = enum ## Reason a queued request was never dispatched.
    rjkCancelled,       ## Its cancellation group was cancelled.
    rjkDeadlineExpired  ## Its dispatch deadline passed in the queue.

  RejectedRequest* = object ## Terminal rejection returned to the driver.
    id*: ScheduledRequestId ## Identity of the rejected request.
    kind*: RejectionKind ## Why the scheduler removed it.

  TakeKind* = enum ## Outcome of polling the deterministic scheduler.
    tkReady, ## A request may be dispatched immediately.
    tkIdle,  ## No queued request requires a wake-up.
    tkWait   ## A request may become eligible at a known instant.

  TakeResult* = object ## Variant returned by `takeReady`.
    case kind*: TakeKind
    of tkReady:
      request*: ScheduledRequest ## Request whose bucket is now reserved.
    of tkWait:
      wakeAt*: MonoMillis ## Earliest instant worth polling again.
    of tkIdle:
      discard

proc initScheduler*(): Scheduler =
  ## Creates an empty scheduler with initialized tables and request IDs.
  result.nextId = 1
  result.nextSequence = 1
  result.routeBuckets = initTable[string, string]()
  result.buckets = initTable[string, BucketState]()
  result.cancelled = initTable[uint64, bool]()

func `==`*(left, right: ScheduledRequestId): bool {.borrow.}
  ## Tests process-local scheduled request identities for equality.

func hash*(id: ScheduledRequestId): Hash =
  ## Returns the table hash of a scheduled request identity.
  hash(uint64(id))

func toUint64*(id: ScheduledRequestId): uint64 =
  ## Exposes an identity for diagnostics and deterministic tests.
  uint64(id)

func provisionalBucket(route: RouteKey): string =
  "route:" & route.canonical()

func bucketFor(scheduler: Scheduler, route: RouteKey): string =
  let routeName = route.canonical()
  scheduler.routeBuckets.getOrDefault(routeName, provisionalBucket(route))

func isCancelled(scheduler: Scheduler, request: RawRequest): bool =
  request.meta.cancellationId.isSome and
    scheduler.cancelled.getOrDefault(request.meta.cancellationId.get(), false)

func isExpired(request: RawRequest, now: MonoMillis): bool =
  request.meta.deadline.isSome and request.meta.deadline.get() <= now

func entryCmp(a, b: QueueEntry): int =
  if a.readyAt != b.readyAt:
    return if a.readyAt < b.readyAt: -1 else: 1
  if a.request.request.meta.priority != b.request.request.meta.priority:
    return cmp(a.request.request.meta.priority,
      b.request.request.meta.priority)
  let aDeadline = a.request.request.meta.deadline
  let bDeadline = b.request.request.meta.deadline
  if aDeadline.isSome and bDeadline.isSome and aDeadline.get() != bDeadline.get():
    return if aDeadline.get() < bDeadline.get(): -1 else: 1
  if aDeadline.isSome != bDeadline.isSome:
    return if aDeadline.isSome: -1 else: 1
  cmp(a.sequence, b.sequence)

proc sortQueue(bucket: var BucketState) =
  bucket.queue.sort(entryCmp)

proc enqueue*(scheduler: var Scheduler, request: sink RawRequest,
              now: MonoMillis): ScheduledRequestId =
  ## Moves a request into its provisional or learned Discord bucket.
  let id = ScheduledRequestId(scheduler.nextId)
  inc scheduler.nextId
  let bucketName = scheduler.bucketFor(request.route)
  var bucket = scheduler.buckets.getOrDefault(bucketName)
  bucket.queue.add QueueEntry(
    request: ScheduledRequest(id: id, request: request, attempt: 1),
    sequence: scheduler.nextSequence,
    readyAt: now
  )
  inc scheduler.nextSequence
  bucket.sortQueue()
  scheduler.buckets[bucketName] = move bucket
  id

proc cancel*(scheduler: var Scheduler, cancellationId: uint64) =
  ## Marks a cancellation group for rejection on the next scheduler poll.
  scheduler.cancelled[cancellationId] = true

proc refreshBucket(bucket: var BucketState, now: MonoMillis) =
  if bucket.resetAt.isSome and bucket.resetAt.get() <= now:
    bucket.resetAt = none(MonoMillis)
    bucket.remaining = bucket.limit

func availableAt(bucket: BucketState, entry: QueueEntry,
                 now: MonoMillis): MonoMillis =
  result = entry.readyAt
  if bucket.remaining.isSome and bucket.remaining.get() <= 0 and
      bucket.resetAt.isSome and result < bucket.resetAt.get():
    result = bucket.resetAt.get()
  if result < now:
    result = now

proc discardInvalid(scheduler: var Scheduler, bucket: var BucketState,
                    now: MonoMillis) =
  var kept: seq[QueueEntry]
  for entry in bucket.queue:
    if scheduler.isCancelled(entry.request.request):
      scheduler.rejections.add RejectedRequest(
        id: entry.request.id,
        kind: rjkCancelled
      )
    elif entry.request.request.isExpired(now):
      scheduler.rejections.add RejectedRequest(
        id: entry.request.id,
        kind: rjkDeadlineExpired
      )
    else:
      kept.add entry
  bucket.queue = move kept

proc takeReady*(scheduler: var Scheduler, now: MonoMillis): TakeResult =
  ## Selects the highest-priority eligible request and reserves its bucket.
  ##
  ## Calls must be followed by `complete` for every `tkReady` result so the
  ## reservation is released. Invalid queued requests are exposed separately
  ## through `takeRejections`.
  if scheduler.globalResetAt.isSome:
    if scheduler.globalResetAt.get() > now:
      return TakeResult(kind: tkWait, wakeAt: scheduler.globalResetAt.get())
    scheduler.globalResetAt = none(MonoMillis)

  var chosenBucket = ""
  var chosenEntry: QueueEntry
  var found = false
  var earliest: Option[MonoMillis]

  for bucketName, storedBucket in scheduler.buckets.mpairs:
    storedBucket.refreshBucket(now)
    scheduler.discardInvalid(storedBucket, now)
    if storedBucket.queue.len == 0:
      continue
    if storedBucket.inFlight > 0:
      # Each learned Discord bucket is serialized. Different buckets still run
      # concurrently in the Chronos driver, and this conservative rule avoids
      # racing multiple first requests before Discord reveals their limit.
      continue
    storedBucket.sortQueue()
    let entry = storedBucket.queue[0]
    let ready = storedBucket.availableAt(entry, now)
    if ready > now:
      if earliest.isNone or ready < earliest.get():
        earliest = some(ready)
      continue
    if not found or entry.entryCmp(chosenEntry) < 0:
      found = true
      chosenBucket = bucketName
      chosenEntry = entry

  if not found:
    if earliest.isSome:
      return TakeResult(kind: tkWait, wakeAt: earliest.get())
    return TakeResult(kind: tkIdle)

  var bucket = scheduler.buckets.getOrDefault(chosenBucket)
  bucket.queue.delete(0)
  inc bucket.inFlight
  if bucket.remaining.isSome:
    bucket.remaining = some(max(0, bucket.remaining.get() - 1))
  scheduler.buckets[chosenBucket] = bucket
  TakeResult(kind: tkReady, request: chosenEntry.request)

proc mergeBuckets(scheduler: var Scheduler, fromName, toName: string) =
  if fromName == toName:
    return
  var destination = scheduler.buckets.getOrDefault(toName)
  if scheduler.buckets.hasKey(fromName):
    let source = scheduler.buckets.getOrDefault(fromName)
    destination.queue.add(source.queue)
    if destination.limit.isNone:
      destination.limit = source.limit
    if destination.remaining.isNone:
      destination.remaining = source.remaining
    if destination.resetAt.isNone:
      destination.resetAt = source.resetAt
    destination.inFlight += source.inFlight
    scheduler.buckets.del(fromName)
  destination.sortQueue()
  scheduler.buckets[toName] = move destination

proc complete*(scheduler: var Scheduler, scheduled: ScheduledRequest,
               update: RateLimitUpdate, now: MonoMillis) =
  ## Releases a bucket reservation and applies response rate-limit facts.
  let routeName = scheduled.request.route.canonical()
  var bucketName = scheduler.bucketFor(scheduled.request.route)
  if update.bucketId.isSome:
    let learnedName = "discord:" & update.bucketId.get() & ":" &
      scheduled.request.route.majorParameter
    scheduler.mergeBuckets(bucketName, learnedName)
    scheduler.routeBuckets[routeName] = learnedName
    bucketName = learnedName

  var bucket = scheduler.buckets.getOrDefault(bucketName)
  if bucket.inFlight > 0:
    dec bucket.inFlight
  if update.limit.isSome:
    bucket.limit = update.limit
  if update.remaining.isSome:
    bucket.remaining = update.remaining
  if update.resetAfterMs.isSome:
    bucket.resetAt = some(now + max(0'i64, update.resetAfterMs.get()))
  if update.wasRateLimited and update.retryAfterMs.isSome:
    let resetAt = now + max(0'i64, update.retryAfterMs.get())
    if update.scope == rlsGlobal:
      scheduler.globalResetAt = some(resetAt)
    else:
      bucket.remaining = some(0)
      bucket.resetAt = some(resetAt)
  scheduler.buckets[bucketName] = bucket

proc retry*(scheduler: var Scheduler, scheduled: sink ScheduledRequest,
            now: MonoMillis): bool =
  ## Requeues a permitted request using capped exponential backoff.
  ##
  ## Returns `false` when idempotency evidence or attempts are exhausted.
  let meta = scheduled.request.meta
  if not meta.canRetry or scheduled.attempt >= meta.retryPolicy.maxAttempts:
    return false
  let bucketName = scheduler.bucketFor(scheduled.request.route)
  var bucket = scheduler.buckets.getOrDefault(bucketName)
  let nextAttempt = scheduled.attempt + 1
  bucket.queue.add QueueEntry(
    request: ScheduledRequest(
      id: scheduled.id,
      request: scheduled.request,
      attempt: nextAttempt
    ),
    sequence: scheduler.nextSequence,
    readyAt: now + meta.retryPolicy.retryDelayMs(nextAttempt)
  )
  inc scheduler.nextSequence
  bucket.sortQueue()
  scheduler.buckets[bucketName] = move bucket
  true

func queuedCount*(scheduler: Scheduler): int =
  ## Returns the total number of requests waiting across all buckets.
  for bucket in scheduler.buckets.values:
    result += bucket.queue.len

func inFlightCount*(scheduler: Scheduler): int =
  ## Returns the number of buckets reserved by active transport attempts.
  for bucket in scheduler.buckets.values:
    result += bucket.inFlight

proc takeRejections*(scheduler: var Scheduler): seq[RejectedRequest] =
  ## Moves all accumulated cancellation and deadline rejections to the caller.
  result = move scheduler.rejections
  scheduler.rejections = @[]
