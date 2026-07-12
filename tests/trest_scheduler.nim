import std/[json, options, strutils, unittest]

import cordnim/rest

proc request(path: string, priority: RequestPriority,
             deadline = none(MonoMillis)): RawRequest =
  RawRequest(
    route: routeKey(hmPost, path, "1"),
    urlPath: path,
    meta: RequestMeta(
      deadline: deadline,
      priority: priority,
      retryPolicy: defaultRetryPolicy(),
      idempotency: idSafe
    )
  )

suite "REST scheduler":
  test "audit reasons are bounded after URL encoding":
    check validateAuditReason("ordinary reason")
    check not validateAuditReason(repeat("あ", 100))
    check not validateAuditReason("line\nbreak")

  test "interaction acknowledgements win inside a ready bucket":
    var scheduler = initScheduler()
    discard scheduler.enqueue(
      request("/channels/{channel}/messages", rpNormal), MonoMillis(0))
    discard scheduler.enqueue(
      request("/channels/{channel}/messages", rpInteractionAck),
      MonoMillis(0))

    let selected = scheduler.takeReady(MonoMillis(0))
    check selected.kind == tkReady
    check selected.request.request.meta.priority == rpInteractionAck

  test "later interaction acknowledgements outrank ready background work":
    var scheduler = initScheduler()
    discard scheduler.enqueue(
      request("/same-bucket", rpBackground), MonoMillis(0))
    discard scheduler.enqueue(
      request("/same-bucket", rpInteractionAck), MonoMillis(1))

    let selected = scheduler.takeReady(MonoMillis(1))
    check selected.kind == tkReady
    check selected.request.request.meta.priority == rpInteractionAck

  test "learned bucket headers delay subsequent requests":
    var scheduler = initScheduler()
    let firstId = scheduler.enqueue(
      request("/channels/{channel}/messages", rpNormal), MonoMillis(0))
    discard firstId
    let first = scheduler.takeReady(MonoMillis(0)).request
    scheduler.complete(first, RateLimitUpdate(
      bucketId: some("messages"),
      limit: some(1),
      remaining: some(0),
      resetAfterMs: some(1_000'i64)
    ), MonoMillis(0))

    discard scheduler.enqueue(
      request("/channels/{channel}/messages", rpNormal), MonoMillis(1))
    let waiting = scheduler.takeReady(MonoMillis(1))
    check waiting.kind == tkWait
    check waiting.wakeAt == MonoMillis(1_000)

  test "out-of-order learned bucket updates cannot shorten a reset":
    var scheduler = initScheduler()
    discard scheduler.enqueue(
      request("/learned-a", rpNormal), MonoMillis(0))
    discard scheduler.enqueue(
      request("/learned-b", rpNormal), MonoMillis(0))
    let first = scheduler.takeReady(MonoMillis(0)).request
    let second = scheduler.takeReady(MonoMillis(0)).request

    scheduler.complete(first, RateLimitUpdate(
      bucketId: some("shared"),
      remaining: some(0),
      resetAfterMs: some(1_000'i64)
    ), MonoMillis(0))
    scheduler.complete(second, RateLimitUpdate(
      bucketId: some("shared"),
      remaining: some(1),
      resetAfterMs: some(100'i64)
    ), MonoMillis(100))

    discard scheduler.enqueue(
      request("/learned-a", rpNormal), MonoMillis(100))
    let waiting = scheduler.takeReady(MonoMillis(200))
    check waiting.kind == tkWait
    check waiting.wakeAt == MonoMillis(1_000)

  test "idle learned buckets are bounded without evicting active resets":
    var scheduler = initScheduler()
    for index in 0..<(MaxRetainedIdleBuckets + 32):
      let path = "/churn/" & $index
      discard scheduler.enqueue(request(path, rpNormal), MonoMillis(0))
      let selected = scheduler.takeReady(MonoMillis(0))
      check selected.kind == tkReady
      scheduler.complete(selected.request, RateLimitUpdate(
        bucketId: some("churn-" & $index)
      ), MonoMillis(0))
    check scheduler.retainedBucketCount <= MaxRetainedIdleBuckets
    check scheduler.learnedRouteCount <= MaxRetainedIdleBuckets

    var active = initScheduler()
    for index in 0..MaxRetainedIdleBuckets:
      let path = "/active-reset/" & $index
      discard active.enqueue(request(path, rpNormal), MonoMillis(0))
      let selected = active.takeReady(MonoMillis(0))
      active.complete(selected.request, RateLimitUpdate(
        bucketId: some("active-reset-" & $index),
        remaining: some(0),
        resetAfterMs: some(1_000'i64)
      ), MonoMillis(0))
    check active.retainedBucketCount == MaxRetainedIdleBuckets + 1
    discard active.takeReady(MonoMillis(1_000))
    check active.retainedBucketCount == MaxRetainedIdleBuckets

  test "bucket waits wake at an earlier queued deadline":
    var scheduler = initScheduler()
    discard scheduler.enqueue(
      request("/channels/{channel}/messages", rpNormal), MonoMillis(0))
    let first = scheduler.takeReady(MonoMillis(0)).request
    scheduler.complete(first, RateLimitUpdate(
      bucketId: some("messages"),
      limit: some(1),
      remaining: some(0),
      resetAfterMs: some(1_000'i64)
    ), MonoMillis(0))

    discard scheduler.enqueue(request(
      "/channels/{channel}/messages",
      rpNormal,
      some(MonoMillis(5))
    ), MonoMillis(1))
    let waiting = scheduler.takeReady(MonoMillis(1))
    check waiting.kind == tkWait
    check waiting.wakeAt == MonoMillis(5)

    check scheduler.takeReady(MonoMillis(5)).kind == tkIdle
    let rejected = scheduler.takeRejections()
    check rejected.len == 1
    check rejected[0].kind == rjkDeadlineExpired

  test "retry waits wake at an earlier request deadline":
    var scheduler = initScheduler()
    discard scheduler.enqueue(request(
      "/safe",
      rpNormal,
      some(MonoMillis(100))
    ), MonoMillis(0))
    var selected = scheduler.takeReady(MonoMillis(0)).request
    scheduler.complete(selected, RateLimitUpdate(), MonoMillis(0))
    check scheduler.retry(selected, MonoMillis(0))

    let waiting = scheduler.takeReady(MonoMillis(0))
    check waiting.kind == tkWait
    check waiting.wakeAt == MonoMillis(100)
    check scheduler.takeReady(MonoMillis(100)).kind == tkIdle
    let rejected = scheduler.takeRejections()
    check rejected.len == 1
    check rejected[0].kind == rjkDeadlineExpired

  test "global waits wake at an earlier queued deadline":
    var scheduler = initScheduler()
    discard scheduler.enqueue(request("/global", rpNormal), MonoMillis(0))
    let first = scheduler.takeReady(MonoMillis(0)).request
    scheduler.complete(first, RateLimitUpdate(
      retryAfterMs: some(1_000'i64),
      scope: rlsGlobal,
      wasRateLimited: true
    ), MonoMillis(0))

    discard scheduler.enqueue(request(
      "/other",
      rpNormal,
      some(MonoMillis(7))
    ), MonoMillis(1))
    let waiting = scheduler.takeReady(MonoMillis(1))
    check waiting.kind == tkWait
    check waiting.wakeAt == MonoMillis(7)

    check scheduler.takeReady(MonoMillis(7)).kind == tkIdle
    let rejected = scheduler.takeRejections()
    check rejected.len == 1
    check rejected[0].kind == rjkDeadlineExpired

  test "out-of-order global limits cannot shorten a reset":
    var scheduler = initScheduler()
    discard scheduler.enqueue(request("/global-a", rpNormal), MonoMillis(0))
    discard scheduler.enqueue(request("/global-b", rpNormal), MonoMillis(0))
    let first = scheduler.takeReady(MonoMillis(0)).request
    let second = scheduler.takeReady(MonoMillis(0)).request

    scheduler.complete(first, RateLimitUpdate(
      retryAfterMs: some(1_000'i64),
      scope: rlsGlobal,
      wasRateLimited: true
    ), MonoMillis(0))
    scheduler.complete(second, RateLimitUpdate(
      retryAfterMs: some(100'i64),
      scope: rlsGlobal,
      wasRateLimited: true
    ), MonoMillis(100))

    discard scheduler.enqueue(request("/global-c", rpNormal), MonoMillis(100))
    let waiting = scheduler.takeReady(MonoMillis(200))
    check waiting.kind == tkWait
    check waiting.wakeAt == MonoMillis(1_000)

  test "expired and cancelled requests are discarded":
    var scheduler = initScheduler()
    var cancelled = request("/a", rpNormal)
    cancelled.meta.cancellationId = some(42'u64)
    discard scheduler.enqueue(cancelled, MonoMillis(0))
    discard scheduler.enqueue(
      request("/b", rpNormal, some(MonoMillis(5))), MonoMillis(0))
    scheduler.cancel(42)

    check scheduler.takeReady(MonoMillis(5)).kind == tkIdle
    check scheduler.queuedCount == 0
    let rejections = scheduler.takeRejections()
    check rejections.len == 2
    check rejections[0].kind == rjkCancelled
    check rejections[1].kind == rjkDeadlineExpired
    check scheduler.activeCancellationGroupCount == 0

  test "cancellation applies only to current members and IDs are reusable":
    var scheduler = initScheduler()
    scheduler.cancel(42)

    var first = request("/first-use", rpNormal)
    first.meta.cancellationId = some(42'u64)
    discard scheduler.enqueue(first, MonoMillis(0))
    let selected = scheduler.takeReady(MonoMillis(0)).request
    scheduler.complete(selected, RateLimitUpdate(), MonoMillis(0))
    scheduler.settle(selected)
    check scheduler.activeCancellationGroupCount == 0

    var cancelled = request("/cancel-current", rpNormal)
    cancelled.meta.cancellationId = some(42'u64)
    discard scheduler.enqueue(cancelled, MonoMillis(1))
    scheduler.cancel(42)
    check scheduler.takeReady(MonoMillis(1)).kind == tkIdle
    let rejected = scheduler.takeRejections()
    check rejected.len == 1
    check rejected[0].kind == rjkCancelled
    check scheduler.activeCancellationGroupCount == 0

    var reused = request("/reused", rpNormal)
    reused.meta.cancellationId = some(42'u64)
    discard scheduler.enqueue(reused, MonoMillis(2))
    let reuseSelected = scheduler.takeReady(MonoMillis(2))
    check reuseSelected.kind == tkReady
    scheduler.complete(
      reuseSelected.request, RateLimitUpdate(), MonoMillis(2))
    scheduler.settle(reuseSelected.request)
    check scheduler.activeCancellationGroupCount == 0

  test "settled cancellation groups do not accumulate":
    var scheduler = initScheduler()
    for cancellationId in 1'u64..64'u64:
      var item = request("/many", rpNormal)
      item.meta.cancellationId = some(cancellationId)
      discard scheduler.enqueue(item, MonoMillis(cancellationId))
      let selected = scheduler.takeReady(MonoMillis(cancellationId))
      check selected.kind == tkReady
      scheduler.complete(
        selected.request, RateLimitUpdate(), MonoMillis(cancellationId))
      scheduler.settle(selected.request)
    check scheduler.activeCancellationGroupCount == 0

  test "retries require explicit idempotency and back off":
    var scheduler = initScheduler()
    discard scheduler.enqueue(request("/safe", rpNormal), MonoMillis(0))
    var selected = scheduler.takeReady(MonoMillis(0)).request
    scheduler.complete(selected, RateLimitUpdate(), MonoMillis(0))
    check scheduler.retry(selected, MonoMillis(0))
    let waiting = scheduler.takeReady(MonoMillis(0))
    check waiting.kind == tkWait
    check waiting.wakeAt == MonoMillis(250)

  test "retry delays follow one-based total attempt semantics":
    let policy = defaultRetryPolicy()
    check policy.retryDelayMs(2) == 250
    check policy.retryDelayMs(3) == 500
    check policy.retryDelayMs(10) == 5_000

    let zeroDelay = RetryPolicy(
      maxAttempts: 1,
      baseDelayMs: 0,
      maxDelayMs: high(int64)
    )
    check zeroDelay.retryDelayMs(high(int)) == 0

    let hugeDelay = RetryPolicy(
      maxAttempts: 1,
      baseDelayMs: 1,
      maxDelayMs: high(int64)
    )
    check hugeDelay.retryDelayMs(high(int)) == high(int64)

  test "invalid retry policies are rejected before queue ownership":
    let invalidPolicies = [
      RetryPolicy(maxAttempts: 0, baseDelayMs: 0, maxDelayMs: 0),
      RetryPolicy(
        maxAttempts: MaxRetryAttempts + 1,
        baseDelayMs: 0,
        maxDelayMs: 0
      ),
      RetryPolicy(maxAttempts: 1, baseDelayMs: -1, maxDelayMs: 0),
      RetryPolicy(maxAttempts: 1, baseDelayMs: 0, maxDelayMs: -1),
      RetryPolicy(maxAttempts: 1, baseDelayMs: 2, maxDelayMs: 1)
    ]
    for policy in invalidPolicies:
      check not policy.valid()
      var scheduler = initScheduler()
      var item = request("/invalid-policy", rpNormal)
      item.meta.retryPolicy = policy
      expect ValueError:
        discard scheduler.enqueue(item, MonoMillis(0))
      check scheduler.queuedCount == 0

    expect ValueError:
      discard initRawRequest(
        routeKey(hmGet, "/invalid-constructor"),
        "/invalid-constructor",
        meta = RequestMeta(retryPolicy: invalidPolicies[0])
      )

  test "retries retain cancellation membership until terminal settlement":
    var scheduler = initScheduler()
    var item = request("/retry-membership", rpNormal)
    item.meta.cancellationId = some(99'u64)
    discard scheduler.enqueue(item, MonoMillis(0))
    let first = scheduler.takeReady(MonoMillis(0)).request
    scheduler.complete(first, RateLimitUpdate(), MonoMillis(0))
    check scheduler.retry(first, MonoMillis(0))
    check scheduler.activeCancellationGroupCount == 1

    let second = scheduler.takeReady(MonoMillis(250))
    check second.kind == tkReady
    check second.request.id == first.id
    scheduler.complete(second.request, RateLimitUpdate(), MonoMillis(250))
    scheduler.settle(second.request)
    check scheduler.activeCancellationGroupCount == 0

  test "non-replayable multipart sources are never requeued":
    var source = memoryUploadSource(@[byte 1, byte 2, byte 3])
    source.replayable = false
    var plan: AttachmentPlan
    plan.add uploadAttachment("once.bin", source)

    var once = request("/once", rpNormal)
    once.body = multipartBody(initMultipartBody(
      %*{"content": "one attempt"},
      plan,
      boundary = "cordnim-once"
    ))

    var scheduler = initScheduler()
    discard scheduler.enqueue(once, MonoMillis(0))
    var selected = scheduler.takeReady(MonoMillis(0)).request
    scheduler.complete(selected, RateLimitUpdate(), MonoMillis(0))
    check not scheduler.retry(selected, MonoMillis(0))
    check scheduler.queuedCount == 0
