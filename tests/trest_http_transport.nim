import std/[options, unittest]

import cordnim/rest

suite "Discord HTTP transport":
  test "rate limit headers are learned dynamically":
    let update = parseRateLimitUpdate(429, [
      ("X-RateLimit-Bucket", "messages"),
      ("X-RateLimit-Limit", "5"),
      ("X-RateLimit-Remaining", "0"),
      ("X-RateLimit-Reset-After", "1.25"),
      ("Retry-After", "2"),
      ("X-RateLimit-Scope", "shared")
    ])
    check update.bucketId == some("messages")
    check update.limit == some(5)
    check update.remaining == some(0)
    check update.resetAfterMs == some(1_250'i64)
    check update.retryAfterMs == some(2_000'i64)
    check update.scope == rlsShared
    check update.wasRateLimited

  test "malformed numeric headers remain unknown":
    let update = parseRateLimitUpdate(200, [
      ("X-RateLimit-Limit", "future"),
      ("X-RateLimit-Reset-After", "later"),
      ("Retry-After", "1e300")
    ])
    check update.limit.isNone
    check update.resetAfterMs.isNone
    check update.retryAfterMs.isNone

  test "negative rate limit delays remain unknown":
    let update = parseRateLimitUpdate(429, [
      ("Retry-After", "-1")
    ])
    check update.retryAfterMs.isNone

  test "absurd finite delays are rejected before integer conversion":
    let boundary = parseRateLimitUpdate(429, [
      ("Retry-After", "9223372036854775")
    ])
    check boundary.retryAfterMs.isNone

    let maximum = parseRateLimitUpdate(429, [
      ("Retry-After", "86400")
    ])
    check maximum.retryAfterMs == some(86_400_000'i64)

    let aboveMaximum = parseRateLimitUpdate(429, [
      ("Retry-After", "86400.001")
    ])
    check aboveMaximum.retryAfterMs.isNone
