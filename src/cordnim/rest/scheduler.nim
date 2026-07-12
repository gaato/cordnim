## Deterministic core for Discord REST rate-limit scheduling.
##
## This module intentionally performs no sleeping and owns no async runtime. A
## single Chronos task drives it by calling `takeReady`, executing the returned
## request, then applying Discord's response headers with `complete`.

import std/[algorithm, hashes, options, sets, strutils, tables]

import ./request

const
  MaxRetainedIdleBuckets* = 1_024
    ## Maximum inactive bucket states retained for route reuse.

type
  RateLimitAuthDomain = enum
    rladPublic
    rladConfigured

  ScheduledRequestId* = distinct uint64 ## Process-local identity assigned when
    ## a request enters the scheduler.

  RateLimitScope* = enum ## Discord scope reported for a rate limit.
    rlsUser, ## Limit applies to the current bot or user identity.
    rlsShared, ## Limit is shared by a resource such as a webhook.
    rlsGlobal ## Limit blocks every request for the current identity.

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
    authDomain: RateLimitAuthDomain

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
    lastTouched: uint64

  CancellationGroupState = object
    members: int
    cancelled: bool

  Scheduler* = object ## Deterministic mutable state for all REST buckets and
    ## queued requests.
    nextId: uint64
    nextSequence: uint64
    nextTouch: uint64
    routeBuckets: Table[string, string]
    buckets: Table[string, BucketState]
    cancellationGroups: Table[uint64, CancellationGroupState]
    cancellationMembers: Table[uint64, uint64]
    globalResetAt: array[RateLimitAuthDomain, Option[MonoMillis]]
    rejections: seq[RejectedRequest]

  RejectionKind* = enum ## Reason a queued request was never dispatched.
    rjkCancelled, ## Its cancellation group was cancelled.
    rjkDeadlineExpired ## Its dispatch deadline passed in the queue.

  RejectedRequest* = object ## Terminal rejection returned to the driver.
    id*: ScheduledRequestId ## Identity of the rejected request.
    kind*: RejectionKind ## Why the scheduler removed it.

  TakeKind* = enum ## Outcome of polling the deterministic scheduler.
    tkReady, ## A request may be dispatched immediately.
    tkIdle, ## No queued request requires a wake-up.
    tkWait ## A request may become eligible at a known instant.

  TakeResult* = object ## Variant returned by `takeReady`.
    case kind*: TakeKind ## Poll outcome selecting the active result variant.
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
  result.nextTouch = 1
  result.routeBuckets = initTable[string, string]()
  result.buckets = initTable[string, BucketState]()
  result.cancellationGroups = initTable[uint64, CancellationGroupState]()
  result.cancellationMembers = initTable[uint64, uint64]()

func `==`*(left, right: ScheduledRequestId): bool {.borrow.}
  ## Tests process-local scheduled request identities for equality.

func hash*(id: ScheduledRequestId): Hash =
  ## Returns the table hash of a scheduled request identity.
  hash(uint64(id))

func toUint64*(id: ScheduledRequestId): uint64 =
  ## Exposes an identity for diagnostics and deterministic tests.
  uint64(id)

func rateLimitAuthDomain(request: RawRequest,
                         configuredIdentityIsPublic: bool):
                         RateLimitAuthDomain =
  if request.authRequirement == darNone or
      (request.authRequirement == darConfigured and
       configuredIdentityIsPublic):
    rladPublic
  else:
    rladConfigured

func domainKey(domain: RateLimitAuthDomain): string =
  case domain
  of rladPublic:
    "public"
  of rladConfigured:
    "configured"

func routeIdentity(request: RawRequest,
                   authDomain: RateLimitAuthDomain): string =
  authDomain.domainKey() & ":" & request.route.canonical()

func provisionalBucket(request: RawRequest,
                       authDomain: RateLimitAuthDomain): string =
  "route:" & request.routeIdentity(authDomain)

func bucketFor(scheduler: Scheduler, request: RawRequest,
               authDomain: RateLimitAuthDomain): string =
  let routeName = request.routeIdentity(authDomain)
  scheduler.routeBuckets.getOrDefault(
    routeName, provisionalBucket(request, authDomain))

func isCancelled(scheduler: Scheduler, request: RawRequest): bool =
  if request.meta.cancellationId.isNone:
    return false
  scheduler.cancellationGroups.getOrDefault(
    request.meta.cancellationId.get()).cancelled

func isExpired(request: RawRequest, now: MonoMillis): bool =
  request.meta.deadline.isSome and request.meta.deadline.get() <= now

proc registerCancellationMember(scheduler: var Scheduler,
                                scheduledId: ScheduledRequestId,
                                cancellationId: Option[uint64]) =
  if cancellationId.isNone:
    return
  let groupId = cancellationId.get()
  var group = scheduler.cancellationGroups.getOrDefault(groupId)
  inc group.members
  scheduler.cancellationGroups[groupId] = group
  scheduler.cancellationMembers[scheduledId.toUint64()] = groupId

proc settle*(scheduler: var Scheduler, scheduled: ScheduledRequest) =
  ## Releases one request from its cancellation group after terminal handling.
  ##
  ## Retries retain the same scheduled ID and must not be settled between
  ## attempts. Repeated calls are harmless.
  let scheduledId = scheduled.id.toUint64()
  if not scheduler.cancellationMembers.hasKey(scheduledId):
    return
  let groupId = scheduler.cancellationMembers.getOrDefault(scheduledId)
  scheduler.cancellationMembers.del(scheduledId)
  var group = scheduler.cancellationGroups.getOrDefault(groupId)
  if group.members <= 1:
    scheduler.cancellationGroups.del(groupId)
  else:
    dec group.members
    scheduler.cancellationGroups[groupId] = group

func entryCmp(a, b: QueueEntry): int =
  # Readiness gates dispatch first. Priority and deadline then reduce latency,
  # while sequence is the final FIFO tie-breaker that prevents reordering peers.
  if a.readyAt != b.readyAt:
    return if a.readyAt < b.readyAt: -1 else: 1
  if a.request.request.meta.priority != b.request.request.meta.priority:
    return cmp(a.request.request.meta.priority,
      b.request.request.meta.priority)
  let aDeadline = a.request.request.meta.deadline
  let bDeadline = b.request.request.meta.deadline
  if aDeadline.isSome and bDeadline.isSome and
      aDeadline.get() != bDeadline.get():
    return if aDeadline.get() < bDeadline.get(): -1 else: 1
  if aDeadline.isSome != bDeadline.isSome:
    return if aDeadline.isSome: -1 else: 1
  cmp(a.sequence, b.sequence)

func dispatchCmp(a, b: QueueEntry): int =
  # `readyAt` gates eligibility but must not outrank an interaction
  # acknowledgement once both requests are ready.
  if a.request.request.meta.priority != b.request.request.meta.priority:
    return cmp(a.request.request.meta.priority,
      b.request.request.meta.priority)
  let aDeadline = a.request.request.meta.deadline
  let bDeadline = b.request.request.meta.deadline
  if aDeadline.isSome and bDeadline.isSome and
      aDeadline.get() != bDeadline.get():
    return if aDeadline.get() < bDeadline.get(): -1 else: 1
  if aDeadline.isSome != bDeadline.isSome:
    return if aDeadline.isSome: -1 else: 1
  cmp(a.sequence, b.sequence)

proc sortQueue(bucket: var BucketState) =
  bucket.queue.sort(entryCmp)

proc touch(scheduler: var Scheduler, bucket: var BucketState) =
  bucket.lastTouched = scheduler.nextTouch
  inc scheduler.nextTouch

proc refreshBucket(bucket: var BucketState, now: MonoMillis) =
  if bucket.resetAt.isSome and bucket.resetAt.get() <= now:
    bucket.resetAt = none(MonoMillis)
    bucket.remaining = bucket.limit

proc pruneIdleBuckets(scheduler: var Scheduler, now: MonoMillis) =
  var candidates: seq[tuple[name: string, touched: uint64]]
  for name, bucket in scheduler.buckets.mpairs:
    bucket.refreshBucket(now)
    if bucket.queue.len == 0 and bucket.inFlight == 0 and
        bucket.resetAt.isNone:
      candidates.add((name, bucket.lastTouched))
  if candidates.len <= MaxRetainedIdleBuckets:
    return
  candidates.sort(proc(a, b: tuple[name: string, touched: uint64]): int =
    if a.touched != b.touched:
      cmp(a.touched, b.touched)
    else:
      cmp(a.name, b.name)
  )
  let removalCount = candidates.len - MaxRetainedIdleBuckets
  var removed = initHashSet[string]()
  for index in 0..<removalCount:
    removed.incl(candidates[index].name)
    scheduler.buckets.del(candidates[index].name)

  var staleRoutes: seq[string]
  for routeName, bucketName in scheduler.routeBuckets.pairs:
    if bucketName in removed:
      staleRoutes.add routeName
  for routeName in staleRoutes:
    scheduler.routeBuckets.del(routeName)

proc enqueue*(scheduler: var Scheduler, request: sink RawRequest,
              now: MonoMillis,
              configuredIdentityIsPublic = false): ScheduledRequestId =
  ## Moves a request into its provisional or learned Discord bucket.
  ##
  ## `configuredIdentityIsPublic` resolves only `darConfigured`; explicit
  ## operation requirements keep their own public or configured identity.
  let policyProblems = request.meta.retryPolicy.validate()
  if policyProblems.len != 0:
    raise newException(ValueError, policyProblems.join("; "))
  scheduler.pruneIdleBuckets(now)
  let id = ScheduledRequestId(scheduler.nextId)
  inc scheduler.nextId
  let cancellationId = request.meta.cancellationId
  scheduler.registerCancellationMember(id, cancellationId)
  let authDomain = request.rateLimitAuthDomain(configuredIdentityIsPublic)
  let bucketName = scheduler.bucketFor(request, authDomain)
  var bucket = scheduler.buckets.getOrDefault(bucketName)
  scheduler.touch(bucket)
  bucket.queue.add(QueueEntry(
    request: ScheduledRequest(
      id: id, request: request, attempt: 1, authDomain: authDomain),
    sequence: scheduler.nextSequence,
    readyAt: now
  ))
  inc scheduler.nextSequence
  bucket.sortQueue()
  scheduler.buckets[bucketName] = move bucket
  id

proc cancel*(scheduler: var Scheduler, cancellationId: uint64) =
  ## Cancels currently known members without leaving a permanent tombstone.
  if scheduler.cancellationGroups.hasKey(cancellationId):
    var group = scheduler.cancellationGroups.getOrDefault(cancellationId)
    group.cancelled = true
    scheduler.cancellationGroups[cancellationId] = group

func availableAt(bucket: BucketState, entry: QueueEntry,
                 now: MonoMillis): MonoMillis =
  result = entry.readyAt
  if bucket.remaining.isSome and bucket.remaining.get() <= 0 and
      bucket.resetAt.isSome and result < bucket.resetAt.get():
    result = bucket.resetAt.get()
  if result < now:
    result = now

func saturatingAdd(now: MonoMillis, delay: int64): MonoMillis =
  let nonNegative = max(0'i64, delay)
  if nonNegative > 0 and int64(now) > high(int64) - nonNegative:
    MonoMillis(high(int64))
  else:
    MonoMillis(int64(now) + nonNegative)

proc discardInvalid(scheduler: var Scheduler, bucket: var BucketState,
                    now: MonoMillis) =
  var kept: seq[QueueEntry]
  for entry in bucket.queue:
    if scheduler.isCancelled(entry.request.request):
      scheduler.rejections.add(RejectedRequest(
        id: entry.request.id,
        kind: rjkCancelled
      ))
      scheduler.settle(entry.request)
    elif entry.request.request.isExpired(now):
      scheduler.rejections.add(RejectedRequest(
        id: entry.request.id,
        kind: rjkDeadlineExpired
      ))
      scheduler.settle(entry.request)
    else:
      kept.add entry
  bucket.queue = move kept

proc takeReady*(scheduler: var Scheduler, now: MonoMillis): TakeResult =
  ## Selects the highest-priority eligible request and reserves its bucket.
  ##
  ## Calls must be followed by `complete` for every `tkReady` result so the
  ## reservation is released. Invalid queued requests are exposed separately
  ## through `takeRejections`.
  for domain in RateLimitAuthDomain:
    if scheduler.globalResetAt[domain].isSome and
        scheduler.globalResetAt[domain].get() <= now:
      scheduler.globalResetAt[domain] = none(MonoMillis)

  var chosenBucket = ""
  var chosenEntry: QueueEntry
  var chosenIndex = -1
  var found = false
  var earliest: Option[MonoMillis]

  for bucketName, storedBucket in scheduler.buckets.mpairs:
    storedBucket.refreshBucket(now)
    scheduler.discardInvalid(storedBucket, now)
    for entry in storedBucket.queue:
      let deadline = entry.request.request.meta.deadline
      if deadline.isSome and
          (earliest.isNone or deadline.get() < earliest.get()):
        earliest = deadline

    if storedBucket.queue.len > 0 and storedBucket.inFlight == 0:
      # Each learned Discord bucket is serialized. Different buckets still run
      # concurrently in the Chronos driver, and this conservative rule avoids
      # racing multiple first requests before Discord reveals their limit.
      let domain = storedBucket.queue[0].request.authDomain
      let globalReset = scheduler.globalResetAt[domain]
      if globalReset.isSome:
        if earliest.isNone or globalReset.get() < earliest.get():
          earliest = globalReset
      else:
        var bucketFound = false
        var bucketEntry: QueueEntry
        var bucketIndex = -1
        for index, entry in storedBucket.queue:
          let ready = storedBucket.availableAt(entry, now)
          if ready > now:
            if earliest.isNone or ready < earliest.get():
              earliest = some(ready)
          elif not bucketFound or entry.dispatchCmp(bucketEntry) < 0:
            bucketFound = true
            bucketEntry = entry
            bucketIndex = index
        if bucketFound and
            (not found or bucketEntry.dispatchCmp(chosenEntry) < 0):
          found = true
          chosenBucket = bucketName
          chosenEntry = bucketEntry
          chosenIndex = bucketIndex

  scheduler.pruneIdleBuckets(now)

  if not found:
    if earliest.isSome:
      return TakeResult(kind: tkWait, wakeAt: earliest.get())
    return TakeResult(kind: tkIdle)

  # Reserve before returning so another poll cannot oversubscribe this bucket.
  # `complete` releases `inFlight` and reconciles remaining with server headers.
  var bucket = scheduler.buckets.getOrDefault(chosenBucket)
  bucket.queue.delete(chosenIndex)
  inc bucket.inFlight
  if bucket.remaining.isSome:
    bucket.remaining = some(max(0, bucket.remaining.get() - 1))
  scheduler.buckets[chosenBucket] = bucket
  TakeResult(kind: tkReady, request: chosenEntry.request)

proc mergeBuckets(scheduler: var Scheduler, fromName, toName: string) =
  if fromName == toName:
    return
  # The first response can replace a provisional route bucket with Discord's
  # bucket ID. Carry its queue and active reservations into the learned bucket;
  # facts already learned there win, while the provisional state fills gaps.
  var destination = scheduler.buckets.getOrDefault(toName)
  if scheduler.buckets.hasKey(fromName):
    let source = scheduler.buckets.getOrDefault(fromName)
    destination.queue.add(source.queue)
    if destination.limit.isNone:
      destination.limit = source.limit
    if destination.remaining.isNone:
      destination.remaining = source.remaining
    elif source.remaining.isSome:
      destination.remaining = some(min(
        destination.remaining.get(), source.remaining.get()))
    if destination.resetAt.isNone:
      destination.resetAt = source.resetAt
    elif source.resetAt.isSome and
        destination.resetAt.get() < source.resetAt.get():
      destination.resetAt = source.resetAt
    destination.inFlight += source.inFlight
    scheduler.buckets.del(fromName)
  destination.sortQueue()
  scheduler.buckets[toName] = move destination

proc complete*(scheduler: var Scheduler, scheduled: ScheduledRequest,
               update: RateLimitUpdate, now: MonoMillis) =
  ## Releases a bucket reservation and applies response rate-limit facts.
  let domain = scheduled.authDomain
  let routeName = scheduled.request.routeIdentity(domain)
  var bucketName = scheduler.bucketFor(scheduled.request, domain)
  if update.bucketId.isSome:
    let learnedName = "discord:" & domain.domainKey() & ":" &
      update.bucketId.get() & ":" & scheduled.request.route.majorParameter
    scheduler.mergeBuckets(bucketName, learnedName)
    scheduler.routeBuckets[routeName] = learnedName
    bucketName = learnedName

  var bucket = scheduler.buckets.getOrDefault(bucketName)
  scheduler.touch(bucket)
  if bucket.inFlight > 0:
    dec bucket.inFlight
  if update.limit.isSome:
    bucket.limit = update.limit
  if update.remaining.isSome:
    if bucket.remaining.isSome:
      bucket.remaining = some(min(
        bucket.remaining.get(), update.remaining.get()))
    else:
      bucket.remaining = update.remaining
  if update.resetAfterMs.isSome:
    let candidate = now.saturatingAdd(update.resetAfterMs.get())
    if bucket.resetAt.isNone or bucket.resetAt.get() < candidate:
      bucket.resetAt = some(candidate)
  if update.wasRateLimited and update.retryAfterMs.isSome:
    let resetAt = now.saturatingAdd(update.retryAfterMs.get())
    if update.scope == rlsGlobal:
      if scheduler.globalResetAt[domain].isNone or
          scheduler.globalResetAt[domain].get() < resetAt:
        scheduler.globalResetAt[domain] = some(resetAt)
    else:
      bucket.remaining = some(0)
      if bucket.resetAt.isNone or bucket.resetAt.get() < resetAt:
        bucket.resetAt = some(resetAt)
  scheduler.buckets[bucketName] = bucket
  scheduler.pruneIdleBuckets(now)

proc retry*(scheduler: var Scheduler, scheduled: ScheduledRequest,
            now: MonoMillis): bool =
  ## Requeues a permitted request using capped exponential backoff.
  ##
  ## Returns `false` when idempotency evidence or attempts are exhausted.
  let meta = scheduled.request.meta
  if scheduled.attempt < 1 or not meta.retryPolicy.valid() or
      not meta.canRetry or not scheduled.request.body.replayable() or
      scheduled.attempt >= meta.retryPolicy.maxAttempts:
    return false
  let bucketName = scheduler.bucketFor(
    scheduled.request, scheduled.authDomain)
  var bucket = scheduler.buckets.getOrDefault(bucketName)
  let nextAttempt = scheduled.attempt + 1
  let delay = meta.retryPolicy.retryDelayMs(nextAttempt)
  let readyAt = now.saturatingAdd(delay)
  bucket.queue.add(QueueEntry(
    request: ScheduledRequest(
      id: scheduled.id,
      request: scheduled.request,
      attempt: nextAttempt,
      authDomain: scheduled.authDomain
    ),
    sequence: scheduler.nextSequence,
    readyAt: readyAt
  ))
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

func activeCancellationGroupCount*(scheduler: Scheduler): int =
  ## Returns live cancellation groups for diagnostics and leak checks.
  scheduler.cancellationGroups.len

func retainedBucketCount*(scheduler: Scheduler): int =
  ## Returns retained provisional and learned bucket states for diagnostics.
  scheduler.buckets.len

func learnedRouteCount*(scheduler: Scheduler): int =
  ## Returns route-to-learned-bucket mappings retained for reuse.
  scheduler.routeBuckets.len

proc takeRejections*(scheduler: var Scheduler): seq[RejectedRequest] =
  ## Moves all accumulated cancellation and deadline rejections to the caller.
  result = move scheduler.rejections
  scheduler.rejections = @[]
