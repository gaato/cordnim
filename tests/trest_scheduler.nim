import std/[options, strutils, unittest]

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
    discard scheduler.enqueue(request("/channels/{channel}/messages", rpNormal), MonoMillis(0))
    discard scheduler.enqueue(request("/channels/{channel}/messages", rpInteractionAck), MonoMillis(0))

    let selected = scheduler.takeReady(MonoMillis(0))
    check selected.kind == tkReady
    check selected.request.request.meta.priority == rpInteractionAck

  test "learned bucket headers delay subsequent requests":
    var scheduler = initScheduler()
    let firstId = scheduler.enqueue(request("/channels/{channel}/messages", rpNormal), MonoMillis(0))
    discard firstId
    let first = scheduler.takeReady(MonoMillis(0)).request
    scheduler.complete(first, RateLimitUpdate(
      bucketId: some("messages"),
      limit: some(1),
      remaining: some(0),
      resetAfterMs: some(1_000'i64)
    ), MonoMillis(0))

    discard scheduler.enqueue(request("/channels/{channel}/messages", rpNormal), MonoMillis(1))
    let waiting = scheduler.takeReady(MonoMillis(1))
    check waiting.kind == tkWait
    check waiting.wakeAt == MonoMillis(1_000)

  test "expired and cancelled requests are discarded":
    var scheduler = initScheduler()
    var cancelled = request("/a", rpNormal)
    cancelled.meta.cancellationId = some(42'u64)
    discard scheduler.enqueue(cancelled, MonoMillis(0))
    discard scheduler.enqueue(request("/b", rpNormal, some(MonoMillis(5))), MonoMillis(0))
    scheduler.cancel(42)

    check scheduler.takeReady(MonoMillis(5)).kind == tkIdle
    check scheduler.queuedCount == 0
    let rejections = scheduler.takeRejections()
    check rejections.len == 2
    check rejections[0].kind == rjkCancelled
    check rejections[1].kind == rjkDeadlineExpired

  test "retries require explicit idempotency and back off":
    var scheduler = initScheduler()
    discard scheduler.enqueue(request("/safe", rpNormal), MonoMillis(0))
    var selected = scheduler.takeReady(MonoMillis(0)).request
    scheduler.complete(selected, RateLimitUpdate(), MonoMillis(0))
    check scheduler.retry(selected, MonoMillis(0))
    let waiting = scheduler.takeReady(MonoMillis(0))
    check waiting.kind == tkWait
    check waiting.wakeAt == MonoMillis(500)
