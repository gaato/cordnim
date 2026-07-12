## Tests for semantic REST scheduling options.

import std/[options, unittest]

import cordnim/api/options
import cordnim/rest/request

suite "semantic REST API options":
  test "caller controls scheduling but the operation controls idempotency":
    let options = initApiCallOptions(
      deadline = some(MonoMillis(5_000)),
      priority = rpForeground,
      auditReason = some("cleanup requested by operator"),
      cancellationId = some(42'u64),
    )
    let meta = options.requestMeta(idSafe)
    check meta.deadline == some(MonoMillis(5_000))
    check meta.priority == rpForeground
    check meta.idempotency == idSafe
    check meta.auditReason == some("cleanup requested by operator")
    check meta.cancellationId == some(42'u64)

  test "invalid retry and audit settings fail before dispatch":
    var invalidRetry = defaultRetryPolicy()
    invalidRetry.maxAttempts = 0
    expect ValueError:
      discard initApiCallOptions(retryPolicy = invalidRetry)
    expect ValueError:
      discard initApiCallOptions(auditReason = some("line one\nline two"))
    expect ValueError:
      discard initApiCallOptions(deadline = some(MonoMillis(-1)))

  test "default construction cannot bypass validation":
    expect ValueError:
      discard ApiCallOptions().requestMeta(idNever)
